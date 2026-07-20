// lib/features/call/agora_call_engine.dart

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/widgets.dart';
import '../../constants.dart';
import '../../services/log_service.dart';
import 'call_engine.dart';

/// Agora-backed [CallEngine] — the original implementation, moved out of
/// CallService unchanged so the hosted path keeps behaving exactly as before.
class AgoraCallEngine implements CallEngine {
  RtcEngine? _engine;
  RtcEngineEventHandler? _handler;
  bool _initialized = false;

  void Function(int)? _onUserJoined;
  void Function(int)? _onUserLeft;
  void Function()? _onError;

  RtcEngine get _requireEngine {
    final e = _engine;
    if (e == null) throw Exception('AgoraCallEngine not initialized');
    return e;
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
        _onUserLeft?.call(remoteUid);
      },
      onError: (err, msg) {
        LogService.e('Call', 'Agora error — code=$err msg=$msg');
        _onError?.call();
      },
      // Observability only — no behavior change. Logs encoder overload /
      // frozen-stream states so low-end-device video problems show up in
      // app_logs instead of being invisible.
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
    required String token,
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  }) async {
    _onUserJoined = onUserJoined;
    _onUserLeft = onUserLeft;
    _onError = onError;

    final myUid = mySenderId == 'A' ? 1 : 2;
    LogService.i('Call',
        'joinCall(agora) — role=$mySenderId uid=$myUid token=${token.isEmpty ? "none" : "set(${token.length})"}');

    await _init();

    await _engine!.enableAudio();
    await _engine!.muteAllRemoteAudioStreams(true);
    if (videoEnabled) {
      await _engine!.enableVideo();
      // Explicit modest profile instead of the SDK default. The critical part
      // is maintainFramerate: the default (maintainQuality) keeps resolution
      // and drops frames when a weak encoder chip can't keep up, which froze
      // video on the lower-capability phone. maintainFramerate lowers
      // resolution under load instead, keeping motion smooth.
      await _engine!.setVideoEncoderConfiguration(
        const VideoEncoderConfiguration(
          dimensions: VideoDimensions(width: 640, height: 360),
          frameRate: 15,
          bitrate: standardBitrate,
          orientationMode: OrientationMode.orientationModeAdaptive,
          degradationPreference: DegradationPreference.maintainFramerate,
        ),
      );
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
  Widget remoteVideoView(int remoteUid) => AgoraVideoView(
        controller: VideoViewController.remote(
          rtcEngine: _requireEngine,
          canvas: VideoCanvas(uid: remoteUid),
          connection: RtcConnection(channelId: agoraChannel),
        ),
      );
}
