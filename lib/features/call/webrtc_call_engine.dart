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

  // ICE candidates that arrive from the other side BEFORE we've applied the
  // remote description must be buffered — addCandidate() before
  // setRemoteDescription is rejected/dropped by WebRTC, which loses the very
  // host/srflx candidates that connect two phones without a relay. Flushed the
  // moment the remote description is set.
  bool _remoteDescSet = false;
  final List<RTCIceCandidate> _pendingRemote = [];

  /// Single remote peer — the uid only exists to satisfy the Agora-shaped API.
  static const int remoteUid = 1;

  Map<String, dynamic> get _iceConfig => {
        'iceServers': [
          {
            'urls': [
              'stun:stun.l.google.com:19302',
              'stun:stun1.l.google.com:19302',
              'stun:stun2.l.google.com:19302',
              'stun:stun3.l.google.com:19302',
              'stun:stun4.l.google.com:19302',
            ]
          },
          if (webrtcTurnUrl.isNotEmpty)
            {
              'urls': webrtcTurnUrl,
              'username': webrtcTurnUsername,
              'credential': webrtcTurnCredential,
            },
        ],
        'sdpSemantics': 'unified-plan',
      };

  @override
  Future<void> join({
    required bool videoEnabled,
    required bool isCaller,
    required String token, // Agora-only; ignored here
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  }) async {
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
    // onTrack fires as soon as the SDP negotiates a track — well before ICE
    // actually connects and media flows. Firing onUserJoined from here (as
    // this used to) marked the call "connected" in the UI immediately, which
    // both showed a black screen/silent audio while the real ICE handshake
    // was still stuck, AND disabled CallScreen's 20s no-answer timeout (it's
    // gated on !_callConnected) — so a call that never actually connects (e.g.
    // a TURN relay that's slow or out of capacity) hung forever with no error
    // shown instead of timing out. onUserJoined now fires from onConnectionState
    // below, once the connection is actually Connected.
    _pc!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isEmpty) return;
      _remoteRenderer.srcObject = event.streams.first;
      LogService.i('Call', 'webrtc: remote track attached (not yet connected)');
    };

    _pc!.onIceConnectionState = (RTCIceConnectionState s) {
      LogService.i('Call', 'webrtc: ICE state $s');
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      LogService.i('Call', 'webrtc: connection state $state');
      if (_leaving) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (!_remoteJoined) {
            _remoteJoined = true;
            LogService.i('Call', 'webrtc: connected — media flowing');
            onUserJoined(remoteUid);
          }
          break;
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

    // Apply the other side's ICE as it trickles in — but only after the remote
    // description is set (buffer until then, see [_remoteDescSet]).
    _subs.add(WebRtcSignaling.remoteCandidateStream(!isCaller).listen((c) {
      final cand = RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        c['sdpMLineIndex'] as int?,
      );
      if (_remoteDescSet) {
        _addCandidate(cand);
      } else {
        _pendingRemote.add(cand);
      }
    }, onError: (e) => LogService.w('Call', 'webrtc: candidate stream $e')));

    if (isCaller) {
      await _offer();
    } else {
      await _answer();
    }
  }

  void _addCandidate(RTCIceCandidate c) {
    _pc?.addCandidate(c).catchError(
        (e) => LogService.w('Call', 'webrtc: addCandidate $e'));
  }

  /// Set the remote description and flush any candidates that arrived early.
  Future<void> _applyRemoteDescription(RTCSessionDescription desc) async {
    if (_remoteDescSet || _pc == null) return; // apply once
    // m-line count is logged alongside the type so a stale/mismatched SDP
    // (e.g. a leftover offer from a previous call with a different track mix)
    // shows up here instead of surfacing only as a cryptic setRemoteDescription
    // error later — see the "Incompatible send direction" issue this caught.
    LogService.i('Call',
        'webrtc: applying remote ${desc.type} (${_countMLines(desc.sdp)} m-line(s))');
    await _pc!.setRemoteDescription(desc);
    _remoteDescSet = true;
    for (final c in _pendingRemote) {
      _addCandidate(c);
    }
    LogService.i('Call',
        'webrtc: remote description applied (flushed ${_pendingRemote.length} buffered candidates)');
    _pendingRemote.clear();
  }

  /// Caller: publish an offer, wait for the answer.
  ///
  /// Stale state from a previous call is cleared by
  /// [CallService.prepareOutgoingCall] BEFORE the callee is rung — doing it
  /// here instead would be too late: the callee starts listening for the
  /// offer as soon as it's rung, which by then can be well before this join()
  /// call (local media capture, peer connection setup) even reaches this
  /// point, letting it read the previous call's leftover offer.
  Future<void> _offer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    LogService.i('Call', 'webrtc: publishing offer (${_countMLines(offer.sdp)} m-line(s))');
    await WebRtcSignaling.setOffer({'type': offer.type, 'sdp': offer.sdp});

    _subs.add(WebRtcSignaling.answerStream().listen((answer) async {
      if (answer == null) return;
      await _applyRemoteDescription(RTCSessionDescription(
          answer['sdp'] as String?, answer['type'] as String?));
    }, onError: (e) => LogService.w('Call', 'webrtc: answer stream $e')));
  }

  /// Callee: wait for the offer, then publish an answer.
  Future<void> _answer() async {
    _subs.add(WebRtcSignaling.offerStream().listen((offer) async {
      if (offer == null || _pc == null || _remoteDescSet) return;
      await _applyRemoteDescription(RTCSessionDescription(
          offer['sdp'] as String?, offer['type'] as String?));
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await WebRtcSignaling.setAnswer({'type': answer.type, 'sdp': answer.sdp});
      LogService.i('Call',
          'webrtc: answer published (${_countMLines(answer.sdp)} m-line(s))');
    }, onError: (e) => LogService.w('Call', 'webrtc: offer stream $e')));
  }

  static int _countMLines(String? sdp) =>
      RegExp('^m=', multiLine: true).allMatches(sdp ?? '').length;

  @override
  Future<void> leave() async {
    _leaving = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _pendingRemote.clear();
    _remoteDescSet = false;
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
