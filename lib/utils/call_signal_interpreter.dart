// lib/utils/call_signal_interpreter.dart
//
// Pure helpers for turning a `callSignal` Firestore map into caller-side call
// stages. Kept Firebase-free so the state machine driving CallScreen's
// "Calling.../Ringing.../Connecting.../Rejected" text is unit-testable.

/// What a `callSignal` update means to the device that did NOT write it.
enum CallSignalEvent {
  /// Not relevant to us (our own write, or a status we don't act on).
  none,

  /// The callee's device has shown the incoming-call UI.
  delivered,

  /// The callee accepted.
  accepted,

  /// The callee declined.
  declined,
}

/// Interprets a `callSignal` map from the perspective of [mySenderId].
///
/// `signal['delivered']` is a separate boolean flag (set by the callee the
/// moment its incoming-call dialog appears) rather than a `status` value, so
/// it never collides with the `status` transitions (`ringing` → `accepted` /
/// `declined` / `ended`) that the caller-cancel auto-dismiss logic in
/// ChatScreen already keys off of.
CallSignalEvent interpretCallSignal(
  Map<String, dynamic>? signal, {
  required String mySenderId,
}) {
  if (signal == null) return CallSignalEvent.none;
  if (signal['from'] == mySenderId) return CallSignalEvent.none;

  final status = signal['status'] as String?;
  switch (status) {
    case 'accepted':
      return CallSignalEvent.accepted;
    case 'declined':
      return CallSignalEvent.declined;
    case 'ringing':
      return signal['delivered'] == true
          ? CallSignalEvent.delivered
          : CallSignalEvent.none;
    default:
      return CallSignalEvent.none;
  }
}

/// The caller-side status label for [CallScreen]'s waiting UI. Only used
/// before the call is connected — once connected the screen shows the call
/// duration instead.
String callerStatusLabel({
  required bool remoteAccepted,
  required bool remoteDelivered,
}) {
  if (remoteAccepted) return 'Connecting...';
  if (remoteDelivered) return 'Ringing...';
  return 'Calling...';
}
