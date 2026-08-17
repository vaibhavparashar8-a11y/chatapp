// lib/features/call/end_minimized_call.dart

import '../../constants.dart';
import '../../services/chat_service.dart';
import '../../services/log_service.dart';
import '../../utils/call_event_text.dart';
import 'call_service.dart';

/// Ends the active call from a minimized surface — the audio mini call bar or
/// the floating video overlay in ChatScreen.
///
/// Both used to only flip [callActiveNotifier] and release the engine, so a
/// call hung up from there wrote no `callEvent` into the chat (nothing showed
/// in CHAT or CALLS) and never set `callSignal.status = ended` for the other
/// device — unlike the full-screen path in `CallScreen._endCall`. This is the
/// one place that teardown lives for both minimized surfaces.
///
/// Lives outside [CallService] so the backend-agnostic media facade stays free
/// of chat concerns.
Future<void> endMinimizedCall() async {
  if (!CallService.inCall) {
    // Engine already gone (remote hung up first) — just clear the UI.
    callActiveNotifier.value = false;
    return;
  }
  final connectedAt = CallService.connectedAt;
  callActiveNotifier.value = false;
  LogService.i('Call', 'endMinimizedCall — connected=${connectedAt != null}');

  // Only the caller writes the event, matching CallScreen — otherwise both
  // devices would log the same call.
  if (isCallCaller) {
    await ChatService.sendCallEvent(callEndEventText(
      isVideo: isCallVideo,
      connectedFor:
          connectedAt == null ? null : DateTime.now().difference(connectedAt),
    ));
  }
  await ChatService.updateCallStatus('ended');
  await CallService.leaveCall();
}
