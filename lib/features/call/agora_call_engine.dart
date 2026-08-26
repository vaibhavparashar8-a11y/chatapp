// lib/features/call/agora_call_engine.dart

import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/widgets.dart';
import '../../constants.dart';
import '../../services/log_service.dart';
import 'call_engine.dart';
import 'video_quality.dart';

/// Agora-backed [CallEngine] — the original implementation, moved out of
/// CallService unchanged so the hosted path keeps behaving exactly as before.
class AgoraCallEngine implements CallEngine {
  RtcEngine? _engine;
  RtcEngineEventHandler? _handler;
  bool _initialized = false;
  bool _videoEnabled = false;

  /// Bumped to force the remote [AgoraVideoView] to be rebuilt from scratch.
  /// See [_scheduleRemoteViewRefresh].
  final ValueNotifier<int> _remoteRevision = ValueNotifier<int>(0);
  Timer? _freezeTimer;

  /// Adaptive resolution: climbs to 720p on a healthy connection and steps
  /// down when the network degrades, driven by `onNetworkQuality`.
  final VideoQualityController _quality = VideoQualityController();

  void Function(int)? _onUserJoined;
  void Function(int)? _onUserLeft;
  void Function()? _onError;

  RtcEngine get _requireEngine {
    final e = _engine;
    if (e == null) throw Exception('AgoraCallEngine not initialized');
    return e;
  }

  /// The remote stream sometimes stays frozen even after Agora reports it
  /// decoding again — the texture the view is bound to never receives another
  /// frame. Leaving the call screen and coming back used to be the only fix,
  /// because that disposed and recreated the view (and with it the
  /// [VideoViewController], which re-runs `setupRemoteVideo`). Bumping
  /// [_remoteRevision] does exactly that in place, without the round trip.
  ///
  /// Delayed, so a brief hiccup that recovers on its own causes no visible
  /// re-attach: the timer is cancelled the moment frames resume.
  void _scheduleRemoteViewRefresh() {
    _freezeTimer?.cancel();
    _freezeTimer = Timer(const Duration(seconds: 3), () {
      LogService.w('Call', 'Remote video still frozen — rebuilding video view');
      _remoteRevision.value++;
    });
  }

  Future<void> _applyEncoderProfile() async {
    final p = _quality.profile;
    await _engine?.setVideoEncoderConfiguration(
      VideoEncoderConfiguration(
        dimensions: VideoDimensions(width: p.width, height: p.height),
        frameRate: p.frameRate,
        bitrate: p.bitrate,
        orientationMode: OrientationMode.orientationModeAdaptive,
        // The critical part: the default (maintainQuality) keeps resolution and
        // drops frames when a weak encoder chip can't keep up, which froze
        // video on the lower-capability phone. maintainFramerate lowers
        // resolution under load instead, keeping motion smooth.
        degradationPreference: DegradationPreference.maintainFramerate,
      ),
    );
    LogService.i('Call',
        'Video profile → ${_quality.level.name} (${p.width}x${p.height}@${p.frameRate}fps ${p.bitrate}kbps)');
  }

  Future<void> _init() async {
    if (_initialized) return;

    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(
      appId: agoraAppId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    _handler = RtcEngineEventHandler(
      onJoinChannelSuccess: (connection, elapsed) {
        LogService.i('Call', 'Joined channel — uid=${connection.localUid}');
      },
      onUserJoined: (connection, remoteUid, elapsed) {
        LogService.i('Call', 'Remote user joined — remoteUid=$remoteUid');
        _engine?.muteAllRemoteAudioStreams(false);
        _onUserJoined?.call(remoteUid);
      },
      onUserOffline: (connection, remoteUid, reason) {
        LogService.i(
            'Call', 'Remote user left — remoteUid=$remoteUid reason=$reason');
        _freezeTimer?.cancel();
        _onUserLeft?.call(remoteUid);
      },
      onError: (err, msg) {
        LogService.e('Call', 'Agora error — code=$err msg=$msg');
        _onError?.call();
      },
      // Drives the adaptive ladder. Fires roughly every 2 s; the report is
      // the summary for this connection.
      onNetworkQuality: (connection, remoteUid, txQuality, rxQuality) {
        if (!_videoEnabled) return;
        final next =
            _quality.onNetworkQuality(txQuality.value(), rxQuality.value());
        if (next != null) unawaited(_applyEncoderProfile());
      },
      // Observability only — no behavior change. Logs encoder overload so
      // low-end-device video problems show up in app_logs instead of being
      // invisible.
      onLocalVideoStateChanged: (source, state, reason) {
        if (state == LocalVideoStreamState.localVideoStreamStateFailed) {
          LogService.w('Call', 'Local video FAILED — reason=$reason');
        }
      },
      onRemoteVideoStateChanged:
          (connection, remoteUid, state, reason, elapsed) {
        if (state == RemoteVideoState.remoteVideoStateFrozen ||
            state == RemoteVideoState.remoteVideoStateFailed) {
          LogService.w(
              'Call', 'Remote video $state — uid=$remoteUid reason=$reason');
          _scheduleRemoteViewRefresh();
        } else if (state == RemoteVideoState.remoteVideoStateDecoding) {
          // Frames are flowing again on their own — no re-attach needed.
          _freezeTimer?.cancel();
        }
      },
      // Fires when the token has already expired at join time, or expires
      // mid-call. onError does NOT fire for this case in Agora SDK 4.x.
      onRequestToken: (connection) {
        LogService.e('Call',
            'Token expired — onRequestToken (channel=${connection.channelId})');
        _onError?.call();
      },
    );
    _engine!.registerEventHandler(_handler!);
    _initialized = true;
  }

  @override
  Future<void> join({
    required bool videoEnabled,
    required bool isCaller, // Agora uses the channel; no explicit caller role
    required String token,
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  }) async {
    _onUserJoined = onUserJoined;
    _onUserLeft = onUserLeft;
    _onError = onError;
    _videoEnabled = videoEnabled;

    final myUid = mySenderId == 'A' ? 1 : 2;
    LogService.i('Call',
        'joinCall(agora) — role=$mySenderId uid=$myUid token=${token.isEmpty ? "none" : "set(${token.length})"}');

    await _init();

    await _engine!.enableAudio();
    await _engine!.muteAllRemoteAudioStreams(true);
    if (videoEnabled) {
      await _engine!.enableVideo();
      // Start on the middle rung: safe on any network, and the ladder climbs
      // to 720p within ~10 s once the connection proves healthy.
      await _applyEncoderProfile();
      await _engine!.startPreview();
    }
    LogService.i('Call', 'Audio/video configured');

    await _engine!.joinChannel(
      token: token,
      channelId: agoraChannel,
      uid: myUid,
      options: ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        publishMicrophoneTrack: true,
        publishCameraTrack: videoEnabled,
        autoSubscribeAudio: true,
        autoSubscribeVideo: videoEnabled,
      ),
    );
    LogService.i(
        'Call', 'joinChannel returned — channel=$agoraChannel uid=$myUid');
  }

  @override
  Future<void> leave() async {
    _onUserJoined = null;
    _onUserLeft = null;
    _onError = null;
    _freezeTimer?.cancel();
    _freezeTimer = null;
    _videoEnabled = false;
    if (_handler != null) {
      _engine?.unregisterEventHandler(_handler!);
      _handler = null;
    }
    await _engine?.leaveChannel();
    await _engine?.stopPreview();
    await _engine?.release();
    _engine = null;
    _initialized = false;
  }

  @override
  Future<void> toggleMute(bool muted) async =>
      _engine?.muteLocalAudioStream(muted);

  @override
  Future<void> toggleSpeaker(bool enabled) async =>
      _engine?.setEnableSpeakerphone(enabled);

  @override
  Future<void> toggleCamera(bool disabled) async =>
      _engine?.muteLocalVideoStream(disabled);

  @override
  Future<void> switchCamera() async => _engine?.switchCamera();

  @override
  Widget localVideoView() => AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: _requireEngine,
          canvas: const VideoCanvas(uid: 0),
        ),
      );

  @override
  Widget remoteVideoView(int remoteUid) => ValueListenableBuilder<int>(
        valueListenable: _remoteRevision,
        builder: (_, revision, __) => AgoraVideoView(
          // The key is what makes a bump tear the stale view down and build a
          // fresh one, re-running setupRemoteVideo against a new texture.
          key: ValueKey('remote-$remoteUid-$revision'),
          controller: VideoViewController.remote(
            rtcEngine: _requireEngine,
            canvas: VideoCanvas(uid: remoteUid),
            connection: RtcConnection(channelId: agoraChannel),
          ),
        ),
      );
}
