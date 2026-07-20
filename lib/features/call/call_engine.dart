// lib/features/call/call_engine.dart

import 'package:flutter/widgets.dart';

/// The media backend behind a call. Two implementations exist:
///
///  * [AgoraCallEngine]  — hosted SFU, billed per minute (10k min/month free).
///  * [WebRtcCallEngine] — direct peer-to-peer, no per-minute cost. Ideal here
///    because the app is always exactly two participants.
///
/// [CallService] owns everything backend-agnostic (screen wakelock, overlay
/// geometry, mute flags, call timer) and delegates only the media work here, so
/// the backend can be swapped by config without touching the UI.
abstract class CallEngine {
  /// Start/join the call and begin publishing.
  ///
  /// [token] is Agora-specific and ignored by peer-to-peer backends.
  /// The callbacks are invoked for remote-participant events; [onError] fires
  /// on an unrecoverable engine/connection failure.
  Future<void> join({
    required bool videoEnabled,
    required String token,
    required void Function(int uid) onUserJoined,
    required void Function(int uid) onUserLeft,
    required void Function() onError,
  });

  /// Tear down: stop publishing, release the engine/peer connection.
  Future<void> leave();

  Future<void> toggleMute(bool muted);
  Future<void> toggleSpeaker(bool enabled);
  Future<void> toggleCamera(bool disabled);
  Future<void> switchCamera();

  /// This device's camera preview.
  Widget localVideoView();

  /// The other participant's video. [remoteUid] is Agora's uid; peer-to-peer
  /// backends have a single remote peer and ignore it.
  Widget remoteVideoView(int remoteUid);
}
