// lib/features/call/call_service.dart

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../constants.dart';
import '../../services/log_service.dart';

class CallService {
  static RtcEngine? _engine;
  static bool _isInitialized = false;
  static RtcEngineEventHandler? _handler;

  // Current remote participant — survives screen minimize/restore
  static int? currentRemoteUid;

  // When the channel was first joined — used to restore timer on reconnect
  static DateTime? callStartTime;

  // UI state persisted across minimize/restore
  static bool isMuted = false;
  static bool isCameraOff = false;
  static bool isSpeakerOn = false;

  // Floating overlay geometry — persisted across minimize/restore so the
  // overlay reopens at the last size/position the user set during THIS call.
  // _FloatingVideoOverlay is force-reconstructed (new Key) every time the user
  // returns from CallScreen, so its own State can't hold this. Reset by
  // joinCall() so a new call always starts at the defaults.
  static const double overlayDefaultX = 16;
  static const double overlayDefaultY = 80;
  static const double overlayDefaultW = 120;
  static const double overlayDefaultH = 160;
  static double overlayX = overlayDefaultX;
  static double overlayY = overlayDefaultY;
  static double overlayW = overlayDefaultW;
  static double overlayH = overlayDefaultH;

  static void resetOverlayGeometry() {
    overlayX = overlayDefaultX;
    overlayY = overlayDefaultY;
    overlayW = overlayDefaultW;
    overlayH = overlayDefaultH;
  }

  // Called when remote user leaves, even while UI is minimized
  static VoidCallback? onCallEnded;

  // Swappable UI callbacks — updated without re-joining the channel
  static void Function(int)? _onUserJoined;
  static void Function(int)? _onUserLeft;
  static void Function()? _onError;

  static Future<void> _init() async {
    if (_isInitialized) return;

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
        currentRemoteUid = remoteUid;
        _engine?.muteAllRemoteAudioStreams(false);
        _onUserJoined?.call(remoteUid);
      },
      onUserOffline: (connection, remoteUid, reason) {
        LogService.i('Call', 'Remote user left — remoteUid=$remoteUid reason=$reason');
        currentRemoteUid = null;
        onCallEnded?.call();
        _onUserLeft?.call(remoteUid);
      },
      onError: (err, msg) {
        LogService.e('Call', 'Agora error — code=$err msg=$msg');
        _onError?.call();
      },
      // Fires when the token has already expired at join time, or expires mid-call.
      // onError does NOT fire for this case in Agora SDK 4.x.
      onRequestToken: (connection) {
        LogService.e('Call', 'Token expired — onRequestToken (channel=${connection.channelId})');
        _onError?.call();
      },
    );
    _engine!.registerEventHandler(_handler!);
    _isInitialized = true;
  }

  /// Swap UI callbacks without re-joining. Used when returning to an active call.
  static void updateCallbacks({
    required void Function(int) onUserJoined,
    required void Function(int) onUserLeft,
    required void Function() onError,
  }) {
    _onUserJoined = onUserJoined;
    _onUserLeft = onUserLeft;
    _onError = onError;
  }

  static RtcEngine get engine {
    if (_engine == null) throw Exception('CallService not initialized');
    return _engine!;
  }

  static Future<void> requestPermissions(bool withVideo) async {
    await Permission.microphone.request();
    if (withVideo) await Permission.camera.request();
  }

  /// True from joinCall until leaveCall — covers full-screen AND minimized
  /// calls. callActiveNotifier only covers the minimized state, which let
  /// ChatScreen's background-leave navigation pop a full-screen CallScreen
  /// and dispose the engine mid-call.
  static bool inCall = false;

  static Future<void> joinCall({
    required bool videoEnabled,
    required String token,
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  }) async {
    inCall = true; // set before any await so a pending leave-timer can't pop us
    resetOverlayGeometry(); // new call → overlay starts at default size/position
    final myUid = mySenderId == 'A' ? 1 : 2;
    LogService.i('Call', 'joinCall — role=$mySenderId uid=$myUid token=${token.isEmpty ? "none" : "set(${token.length})"}');

    updateCallbacks(onUserJoined: onUserJoined, onUserLeft: onUserLeft, onError: onError);
    await _init();
    await requestPermissions(videoEnabled);

    await _engine!.enableAudio();
    await _engine!.muteAllRemoteAudioStreams(true);
    if (videoEnabled) {
      await _engine!.enableVideo();
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
    callStartTime = DateTime.now();
    LogService.i('Call', 'joinChannel returned — channel=$agoraChannel uid=$myUid');
  }

  static Future<void> leaveCall() async {
    LogService.i('Call', 'leaveCall — releasing engine');
    inCall = false;
    // Centralized here so EVERY teardown path (error, timeout, remote hangup)
    // hides the overlay/mini-bar. The scattered per-callback resets in
    // CallScreen missed atypical paths, leaving the overlay to appear
    // "mistakenly" on a later ChatScreen build with no live call.
    callActiveNotifier.value = false;
    _onUserJoined = null;
    _onUserLeft = null;
    _onError = null;
    onCallEnded = null;
    currentRemoteUid = null;
    callStartTime = null;
    isMuted = false;
    isCameraOff = false;
    isSpeakerOn = false;
    if (_handler != null) {
      _engine?.unregisterEventHandler(_handler!);
      _handler = null;
    }
    await _engine?.leaveChannel();
    await _engine?.stopPreview();
    await _engine?.release();
    _engine = null;
    _isInitialized = false;
  }

  static Future<void> toggleMute(bool muted) async {
    isMuted = muted;
    await _engine?.muteLocalAudioStream(muted);
  }

  static Future<void> toggleSpeaker(bool enabled) async {
    isSpeakerOn = enabled;
    await _engine?.setEnableSpeakerphone(enabled);
  }

  static Future<void> toggleCamera(bool disabled) async {
    isCameraOff = disabled;
    await _engine?.muteLocalVideoStream(disabled);
  }

  static Future<void> switchCamera() async {
    await _engine?.switchCamera();
  }

  static Future<void> dispose() async {
    await leaveCall();
  }
}
