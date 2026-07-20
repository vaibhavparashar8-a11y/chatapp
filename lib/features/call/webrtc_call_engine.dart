// lib/features/call/webrtc_call_engine.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../constants.dart';
import '../../services/log_service.dart';
import 'call_engine.dart';
import 'webrtc_signaling.dart';

/// Peer-to-peer [CallEngine] — media flows directly between the two phones, so
/// there is no per-minute cost and usually lower latency than a hosted SFU.
///
/// Signalling (offer/answer/ICE) rides Firestore via [WebRtcSignaling]. Which
/// side offers is decided by [isCallCaller], already set by the existing call
/// flow, so no extra negotiation is needed.
///
/// NAT traversal: STUN alone connects most networks, but two phones on mobile
/// data behind carrier-grade NAT need a TURN relay. Configure TURN via Remote
/// Config (`webrtc_turn_url` / `_username` / `_credential`) — without it those
/// calls will fail to connect.
class WebRtcCallEngine implements CallEngine {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  final _subs = <StreamSubscription<dynamic>>[];
  bool _remoteJoined = false;
  bool _leaving = false;

  /// Single remote peer — the uid only exists to satisfy the Agora-shaped API.
  static const int remoteUid = 1;

  Map<String, dynamic> get _iceConfig => {
        'iceServers': [
          {
            'urls': [
              'stun:stun.l.google.com:19302',
              'stun:stun1.l.google.com:19302',
            ]
          },
          if (webrtcTurnUrl.isNotEmpty)
            {
              'urls': webrtcTurnUrl,
              'username': webrtcTurnUsername,
              'credential': webrtcTurnCredential,
            },
        ],
        // Trickle ICE: send candidates as they're found instead of waiting.
        'sdpSemantics': 'unified-plan',
      };

  @override
  Future<void> join({
    required bool videoEnabled,
    required String token, // Agora-only; ignored here
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  }) async {
    final isCaller = isCallCaller;
    LogService.i('Call',
        'joinCall(webrtc) — role=$mySenderId caller=$isCaller video=$videoEnabled turn=${webrtcTurnUrl.isEmpty ? "none" : "set"}');

    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _pc = await createPeerConnection(_iceConfig);

    // ── Local media ────────────────────────────────────────────────────────
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': videoEnabled
          ? {
              'facingMode': 'user',
              // Match the Agora profile: modest resolution keeps weak encoders
              // smooth rather than dropping frames.
              'width': {'ideal': 640},
              'height': {'ideal': 360},
              'frameRate': {'ideal': 15},
            }
          : false,
    });
    _localRenderer.srcObject = _localStream;
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // ── Remote media ───────────────────────────────────────────────────────
    _pc!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isEmpty) return;
      _remoteRenderer.srcObject = event.streams.first;
      if (!_remoteJoined) {
        _remoteJoined = true;
        LogService.i('Call', 'webrtc: remote stream connected');
        onUserJoined(remoteUid);
      }
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      LogService.i('Call', 'webrtc: connection state $state');
      if (_leaving) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          LogService.e('Call',
              'webrtc: connection FAILED — likely NAT traversal (TURN needed?)');
          onError();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (_remoteJoined) onUserLeft(remoteUid);
          break;
        default:
          break;
      }
    };

    // ── Signalling ─────────────────────────────────────────────────────────
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      WebRtcSignaling.addCandidate(isCaller, {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }).catchError((e) => LogService.w('Call', 'webrtc: candidate write $e'));
    };

    // Apply the other side's ICE as it trickles in.
    _subs.add(WebRtcSignaling.remoteCandidateStream(!isCaller).listen((c) {
      _pc?.addCandidate(RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        c['sdpMLineIndex'] as int?,
      ));
    }, onError: (e) => LogService.w('Call', 'webrtc: candidate stream $e')));

    if (isCaller) {
      await _offer();
    } else {
      await _answer();
    }
  }

  /// Caller: clear stale state, publish an offer, wait for the answer.
  Future<void> _offer() async {
    await WebRtcSignaling.reset();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await WebRtcSignaling.setOffer({'type': offer.type, 'sdp': offer.sdp});

    _subs.add(WebRtcSignaling.answerStream().listen((answer) async {
      if (answer == null || _pc == null) return;
      final desc = await _pc!.getRemoteDescription();
      if (desc != null) return; // already applied
      await _pc!.setRemoteDescription(
        RTCSessionDescription(answer['sdp'] as String?, answer['type'] as String?),
      );
      LogService.i('Call', 'webrtc: answer applied');
    }, onError: (e) => LogService.w('Call', 'webrtc: answer stream $e')));
  }

  /// Callee: wait for the offer, then publish an answer.
  Future<void> _answer() async {
    _subs.add(WebRtcSignaling.offerStream().listen((offer) async {
      if (offer == null || _pc == null) return;
      final desc = await _pc!.getRemoteDescription();
      if (desc != null) return; // already applied
      await _pc!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String?, offer['type'] as String?),
      );
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await WebRtcSignaling.setAnswer({'type': answer.type, 'sdp': answer.sdp});
      LogService.i('Call', 'webrtc: answer published');
    }, onError: (e) => LogService.w('Call', 'webrtc: offer stream $e')));
  }

  @override
  Future<void> leave() async {
    _leaving = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    _remoteJoined = false;
  }

  @override
  Future<void> toggleMute(bool muted) async {
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  Future<void> toggleSpeaker(bool enabled) async {
    // Routes audio to the loudspeaker vs the earpiece.
    await Helper.setSpeakerphoneOn(enabled);
  }

  @override
  Future<void> toggleCamera(bool disabled) async {
    for (final t in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !disabled;
    }
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  @override
  Widget localVideoView() =>
      RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);

  @override
  Widget remoteVideoView(int remoteUid) => RTCVideoView(_remoteRenderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
}
