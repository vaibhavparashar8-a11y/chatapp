// lib/features/call/end_minimized_call.dart

import 'package:flutter/foundation.dart' show visibleForTesting;
import '../../constants.dart';
import '../../services/chat_service.dart';
import '../../services/log_service.dart';
import '../../utils/call_event_text.dart';
import 'call_service.dart';

/// Test seams — the production path goes straight to [ChatService], which needs
/// Firebase. Overriding these lets the who-writes-what rules be asserted, which
/// is worth doing: this teardown has been the source of two "the call left no
/// trace in the chat" bugs.
@visibleForTesting
Future<void> Function(String text)? sendCallEventOverride;
@visibleForTesting
Future<void> Function(String status)? updateCallStatusOverride;
@visibleForTesting
Future<void> Function()? leaveCallOverride;

/// Guards against two teardowns racing — e.g. the user taps End at the same
/// moment the remote hangs up — which would log the call twice.
bool _ending = false;

@visibleForTesting
void resetEndMinimizedCallGuard() => _ending = false;

/// Ends the active call from a minimized surface: the audio mini call bar, the
/// floating video overlay, or a remote hang-up while either is showing.
///
/// Who writes the chat entry: **the caller only**, matching
/// `CallScreen._endCall`. Both devices read the same room, so one write is
/// what puts "Video call ended • 02:14" on both phones — and it is why this
/// must also run on the caller's side when the *callee* is the one who hangs
/// up. Tearing down silently there (the old behaviour) meant a call ended by
/// the callee, with the caller minimized, was never logged by anyone.
Future<void> endMinimizedCall() async {
  if (!CallService.inCall || _ending) {
    // Engine already gone (or another teardown is mid-flight) — just make sure
    // the pip/mini bar is not left on screen.
    callActiveNotifier.value = false;
    return;
  }
  _ending = true;
  try {
    final connectedAt = CallService.connectedAt;
    callActiveNotifier.value = false;
    LogService.i('Call', 'endMinimizedCall — connected=${connectedAt != null} '
        'caller=$isCallCaller');

    if (isCallCaller) {
      final text = callEndEventText(
        isVideo: isCallVideo,
        connectedFor:
            connectedAt == null ? null : DateTime.now().difference(connectedAt),
      );
      await (sendCallEventOverride ?? ChatService.sendCallEvent)(text);
    }
    await (updateCallStatusOverride ?? ChatService.updateCallStatus)('ended');
    await (leaveCallOverride ?? CallService.leaveCall)();
  } finally {
    _ending = false;
  }
}
