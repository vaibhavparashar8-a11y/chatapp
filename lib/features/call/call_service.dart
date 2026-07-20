// lib/features/call/call_service.dart

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../constants.dart';
import '../../services/log_service.dart';
import 'agora_call_engine.dart';
import 'call_engine.dart';
import 'webrtc_call_engine.dart';

/// Backend-agnostic call facade.
///
/// Owns everything that is the same whichever backend runs the media: screen
/// wakelock, overlay geometry, mute/camera/speaker flags, the call timer, and
/// the swappable UI callbacks. The actual media work is delegated to a
/// [CallEngine] chosen at join time from [callBackend] (Remote Config
/// `call_backend`: `agora` — default — or `webrtc`).
class CallService {
  // Native channel shared with CallScreen — also drives the screen wakelock so
  // a video call keeps the display awake for the whole call (full-screen AND
  // minimized), released centrally in [leaveCall].
  static const _callChannel = MethodChannel('com.example.chatapp/call');

  static CallEngine? _engine;

  /// Which backend the ACTIVE call is using (null when no call). Exposed for
  /// diagnostics/logging so a misbehaving call can be traced to its backend.
  static String? activeBackend;

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

  // Swappable UI callbacks — updated without re-joining the channel. The engine
  // receives the stable _handle* wrappers below, so swapping these never needs
  // the engine to be touched.
  static void Function(int)? _onUserJoined;
  static void Function(int)? _onUserLeft;
  static void Function()? _onError;

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

  static void _handleUserJoined(int uid) {
    currentRemoteUid = uid;
    _onUserJoined?.call(uid);
  }

  static void _handleUserLeft(int uid) {
    currentRemoteUid = null;
    onCallEnded?.call();
    _onUserLeft?.call(uid);
  }

  static void _handleError() => _onError?.call();

  static Future<void> requestPermissions(bool withVideo) async {
    await Permission.microphone.request();
    if (withVideo) await Permission.camera.request();
  }

  /// True from joinCall until leaveCall — covers full-screen AND minimized
  /// calls. callActiveNotifier only covers the minimized state, which let
  /// ChatScreen's background-leave navigation pop a full-screen CallScreen
  /// and dispose the engine mid-call.
  static bool inCall = false;

  /// Build the engine for [backend]. Anything other than `webrtc` falls back to
  /// Agora, so a bad/blank/typo'd config value can never leave calls without a
  /// working backend.
  @visibleForTesting
  static CallEngine createEngineForBackend(String backend) =>
      backend.trim().toLowerCase() == 'webrtc'
          ? WebRtcCallEngine()
          : AgoraCallEngine();

  static CallEngine _createEngine() => createEngineForBackend(callBackend);

  static Future<void> joinCall({
    required bool videoEnabled,
    required bool isCaller,
    required String token,
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  }) async {
    inCall = true; // set before any await so a pending leave-timer can't pop us
    // Video calls: keep the screen awake for the whole call. Audio calls rely on
    // the proximity wakelock (see CallScreen) instead, so the screen can still
    // switch off when held to the ear.
    if (videoEnabled) {
      _callChannel.invokeMethod('keepScreenOn').catchError((_) {});
    }
    resetOverlayGeometry(); // new call → overlay starts at default size/position

    updateCallbacks(
        onUserJoined: onUserJoined, onUserLeft: onUserLeft, onError: onError);
    await requestPermissions(videoEnabled);

    _engine = _createEngine();
    activeBackend = callBackend == 'webrtc' ? 'webrtc' : 'agora';
    LogService.i('Call',
        'joinCall — backend=$activeBackend video=$videoEnabled caller=$isCaller');

    await _engine!.join(
      videoEnabled: videoEnabled,
      isCaller: isCaller,
      token: token,
      onUserJoined: _handleUserJoined,
      onUserLeft: _handleUserLeft,
      onError: _handleError,
    );
    callStartTime = DateTime.now();
  }

  static Future<void> leaveCall() async {
    LogService.i('Call', 'leaveCall — releasing engine ($activeBackend)');
    inCall = false;
    // Always clear the screen-on flag (no-op if it was an audio call).
    _callChannel.invokeMethod('allowScreenOff').catchError((_) {});
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
    await _engine?.leave();
    _engine = null;
    activeBackend = null;
  }

  static Future<void> toggleMute(bool muted) async {
    isMuted = muted;
    await _engine?.toggleMute(muted);
  }

  static Future<void> toggleSpeaker(bool enabled) async {
    isSpeakerOn = enabled;
    await _engine?.toggleSpeaker(enabled);
  }

  static Future<void> toggleCamera(bool disabled) async {
    isCameraOff = disabled;
    await _engine?.toggleCamera(disabled);
  }

  static Future<void> switchCamera() async => _engine?.switchCamera();

  /// Local camera preview for the active backend. Renders nothing when no call
  /// is live (the UI only builds these while `_engineReady`).
  static Widget localVideoView() =>
      _engine?.localVideoView() ?? const SizedBox.shrink();

  /// Remote participant's video for the active backend.
  static Widget remoteVideoView(int remoteUid) =>
      _engine?.remoteVideoView(remoteUid) ?? const SizedBox.shrink();

  static Future<void> dispose() async {
    await leaveCall();
  }
}
