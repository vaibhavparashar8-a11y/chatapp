import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/utils/time_utils.dart';

void main() {
  // ── formatLastSeen ──────────────────────────────────────────────────────────

  group('formatLastSeen', () {
    test('returns "just now" for timestamps less than 1 minute ago', () {
      final ts = DateTime.now().subtract(const Duration(seconds: 30));
      expect(formatLastSeen(ts), 'just now');
    });

    test('returns "today at HH:MM" for a timestamp earlier today', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day, 9, 0)
          .subtract(const Duration(minutes: 1)); // ensure > 1 min ago
      // Only meaningful when current time > 09:01
      if (now.hour > 9 || (now.hour == 9 && now.minute >= 1)) {
        expect(formatLastSeen(ts), startsWith('today at'));
      }
    });

    // ── The key regression test for issue #1 ─────────────────────────────────
    test('yesterday at 22:00 shows "yesterday" even when fewer than 24 h ago', () {
      final now = DateTime.now();
      // Build a timestamp that is always "yesterday at 22:00", which is < 24 h
      // ago whenever the current time is before 22:00 today.
      final yesterdayAt22 = DateTime(now.year, now.month, now.day - 1, 22, 0);
      final result = formatLastSeen(yesterdayAt22);
      expect(result, startsWith('yesterday at'),
          reason: 'Calendar day must be used, not elapsed hours. '
              'Got: "$result" for ts=$yesterdayAt22, now=$now');
    });

    test('never returns "today" for a timestamp on a previous calendar day', () {
      final now = DateTime.now();
      final yesterdayMorning = DateTime(now.year, now.month, now.day - 1, 8, 0);
      expect(formatLastSeen(yesterdayMorning), isNot(startsWith('today')));
    });

    test('returns DD/MM format for timestamps older than yesterday', () {
      final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
      final result = formatLastSeen(twoDaysAgo);
      expect(result, contains('/'));
      expect(result, isNot(startsWith('today')));
      expect(result, isNot(startsWith('yesterday')));
      expect(result, isNot('just now'));
    });

    test('HH:MM is zero-padded', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day - 1, 9, 5);
      final result = formatLastSeen(ts);
      expect(result, contains('09:05'));
    });
  });

  // ── formatDue ───────────────────────────────────────────────────────────────

  group('formatDue', () {
    test('returns "Due today at HH:MM" for a time later today', () {
      final now = DateTime.now();
      final laterToday = DateTime(now.year, now.month, now.day, 23, 59);
      expect(formatDue(laterToday), 'Due today at 23:59');
    });

    test('returns "Due tomorrow at HH:MM" for a time tomorrow', () {
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 10, 30);
      expect(formatDue(tomorrow), 'Due tomorrow at 10:30');
    });

    test('returns "Was due DD/MM at HH:MM" for a past date', () {
      final past = DateTime(2020, 3, 5, 14, 0);
      expect(formatDue(past), 'Was due 5/3 at 14:00');
    });

    test('returns "Due DD/MM at HH:MM" for a future date beyond tomorrow', () {
      final now = DateTime.now();
      final future = DateTime(now.year, now.month, now.day + 5, 8, 0);
      final result = formatDue(future);
      expect(result, startsWith('Due '));
      expect(result, isNot(contains('today')));
      expect(result, isNot(contains('tomorrow')));
      expect(result, isNot(startsWith('Was')));
    });

    test('HH:MM is zero-padded for single-digit hours and minutes', () {
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 9, 5);
      expect(formatDue(tomorrow), 'Due tomorrow at 09:05');
    });

    test('"today" and "yesterday" are consistent — yesterday is never "today"', () {
      final now = DateTime.now();
      final yesterdayDue = DateTime(now.year, now.month, now.day - 1, 12, 0);
      expect(formatDue(yesterdayDue), startsWith('Was due'));
    });
  });

  // ── parseReminderTimestamp ──────────────────────────────────────────────────

  group('parseReminderTimestamp', () {
    // Regression: FCM payloads carry UTC ISO strings ("...Z"). Displaying the
    // parsed hour without converting to local showed UTC wall-clock time —
    // a 22:30 IST reminder appeared as 17:00 in B's notification.
    test('converts a UTC payload string to local time', () {
      final parsed = parseReminderTimestamp('2030-01-01T17:00:00.000Z');
      expect(parsed, isNotNull);
      expect(parsed!.isUtc, isFalse,
          reason: 'must be local so .hour formats as local wall-clock time');
      // Same instant — only the representation changes.
      expect(parsed.isAtSameMomentAs(DateTime.utc(2030, 1, 1, 17)), isTrue);
    });

    test('keeps a local (offset-free) string as-is', () {
      final parsed = parseReminderTimestamp('2030-01-01T22:30:00.000');
      expect(parsed, isNotNull);
      expect(parsed!.hour, 22);
      expect(parsed.minute, 30);
    });

    test('returns null for garbage input', () {
      expect(parseReminderTimestamp('not-a-date'), isNull);
    });
  });
}
