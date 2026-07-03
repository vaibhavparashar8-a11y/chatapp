/// Shared time-formatting helpers used by ChatScreen and TodoScreen.
/// Kept in a standalone file so they can be unit-tested without Flutter widgets.

/// Format a "last seen" timestamp for display in the chat app bar.
///
/// Uses calendar-day comparison, NOT elapsed hours, so a timestamp from
/// yesterday at 22:00 seen at 08:00 today (10 hrs apart) shows as
/// "yesterday at 22:00", not "today at 22:00".
String formatLastSeen(DateTime ts) {
  final now = DateTime.now();
  final hm = _hm(ts);
  if (now.difference(ts).inMinutes < 1) return 'just now';
  final today = DateTime(now.year, now.month, now.day);
  final calendarDiff =
      today.difference(DateTime(ts.year, ts.month, ts.day)).inDays;
  if (calendarDiff == 0) return 'today at $hm';
  if (calendarDiff == 1) return 'yesterday at $hm';
  return '${ts.day}/${ts.month} at $hm';
}

/// Format a task due date for display as a subtitle on a to-do tile.
String formatDue(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final dtDay = DateTime(dt.year, dt.month, dt.day);
  final diff = dtDay.difference(today).inDays;
  final hm = _hm(dt);
  if (diff < 0) return 'Was due ${dt.day}/${dt.month} at $hm';
  if (diff == 0) return 'Due today at $hm';
  if (diff == 1) return 'Due tomorrow at $hm';
  return 'Due ${dt.day}/${dt.month} at $hm';
}

String _hm(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

/// Parse an ISO-8601 timestamp from an FCM data payload into LOCAL time.
///
/// The Cloud Function serialises Firestore timestamps with toISOString(),
/// which is always UTC ("...Z"). DateTime.parse keeps that UTC flag, so
/// formatting its .hour directly shows UTC wall-clock time — off by the
/// device's UTC offset (e.g. 5:30 for IST: a 22:30 reminder displayed
/// as 17:00). Converting to local fixes display, scheduling and storage.
DateTime? parseReminderTimestamp(String iso) =>
    DateTime.tryParse(iso)?.toLocal();
