// lib/utils/call_event_text.dart
//
// Pure helpers for the `callEvent` chat entry written when a call ends. Kept
// Firebase-free so the wording — which the Calls tab also parses (it keys off
// "missed"/"video") — is unit-testable.

/// `mm:ss`, matching the live duration label shown on CallScreen.
String formatCallDuration(Duration d) {
  final s = d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}

/// Text of the callEvent the CALLER writes when a call ends.
///
/// [connectedFor] is null when the other side never joined — the call is then
/// logged as missed, exactly as CallScreen does for a hang-up before answer or
/// the 20 s setup timeout.
String callEndEventText({required bool isVideo, required Duration? connectedFor}) {
  final label = isVideo ? 'Video call' : 'Audio call';
  if (connectedFor == null) return 'Missed $label';
  return '$label ended • ${formatCallDuration(connectedFor)}';
}
