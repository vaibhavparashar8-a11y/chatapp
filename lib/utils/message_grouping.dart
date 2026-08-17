// lib/utils/message_grouping.dart
//
// Decides how a flat message list is presented: where a date separator goes,
// and which consecutive messages form one visual run. Pure and Flutter-free so
// the rules are unit-testable — they are easy to get subtly wrong (a run that
// spans midnight, a call event splitting a run) and the bugs are visual only.

import '../models/message.dart';

/// How one message should be drawn, given its neighbours.
class MessageLayout {
  /// A date separator chip goes above this message.
  final bool showDateChip;

  /// First message of a run by the same sender — the one that gets the top
  /// margin separating it from the previous person.
  final bool isFirstInGroup;

  /// Last of the run: only this one draws the tail and the timestamp row, so a
  /// burst of messages reads as one block instead of repeating the clock.
  final bool isLastInGroup;

  const MessageLayout({
    required this.showDateChip,
    required this.isFirstInGroup,
    required this.isLastInGroup,
  });
}

/// Longest gap between two messages that still counts as the same run.
const _groupWindow = Duration(minutes: 5);

/// Layout decisions for [messages], oldest first — index-aligned with the input.
List<MessageLayout> layoutMessages(
  List<Message> messages, {
  Duration groupWindow = _groupWindow,
}) {
  return List.generate(messages.length, (i) {
    final msg = messages[i];
    final prev = i > 0 ? messages[i - 1] : null;
    final next = i < messages.length - 1 ? messages[i + 1] : null;

    return MessageLayout(
      showDateChip: prev == null || !isSameDay(prev.timestamp, msg.timestamp),
      isFirstInGroup: !_groupsWith(prev, msg, groupWindow),
      isLastInGroup: !_groupsWith(msg, next, groupWindow),
    );
  });
}

/// Whether [b] continues [a]'s run.
///
/// Call events never group: they are centred dividers, not bubbles, so letting
/// them join a run would hide the tail and timestamp of a real message.
bool _groupsWith(Message? a, Message? b, Duration window) {
  if (a == null || b == null) return false;
  if (a.type == MessageType.callEvent || b.type == MessageType.callEvent) {
    return false;
  }
  if (a.sender != b.sender) return false;
  if (!isSameDay(a.timestamp, b.timestamp)) return false;
  return b.timestamp.difference(a.timestamp).abs() <= window;
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Label for the date separator: "Today", "Yesterday", "Mon 14 Aug" within the
/// last week, otherwise "14 Aug 2026".
///
/// [now] is injectable so the tests do not depend on the clock.
String formatDateSeparator(DateTime ts, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final startOfToday = DateTime(today.year, today.month, today.day);
  final startOfDay = DateTime(ts.year, ts.month, ts.day);
  final days = startOfToday.difference(startOfDay).inDays;

  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) return '${_weekday(ts.weekday)} ${ts.day} ${_month(ts.month)}';
  if (ts.year == today.year) return '${ts.day} ${_month(ts.month)}';
  return '${ts.day} ${_month(ts.month)} ${ts.year}';
}

String _weekday(int weekday) => const [
      'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
    ][weekday - 1];

String _month(int month) => const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ][month - 1];
