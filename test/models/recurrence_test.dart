import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/recurrence.dart';

void main() {
  group('Recurrence storage', () {
    test('round-trips through storage name', () {
      for (final r in Recurrence.values) {
        expect(Recurrence.fromStorage(r.storage), r);
      }
    });

    test('fromStorage falls back to none for null/unknown', () {
      expect(Recurrence.fromStorage(null), Recurrence.none);
      expect(Recurrence.fromStorage('bogus'), Recurrence.none);
    });
  });

  group('Recurrence.daySlotMinutes — intra-day intervals', () {
    // The whole of the interval feature's logic lives here: each slot becomes
    // one ordinary daily notification, so getting these times right is what
    // makes "every 90 minutes" work.
    String hhmm(int mins) =>
        '${(mins ~/ 60).toString().padLeft(2, '0')}:'
        '${(mins % 60).toString().padLeft(2, '0')}';

    test('a non-interval rule fires once, at the picked time', () {
      for (final r in [
        Recurrence.none,
        Recurrence.daily,
        Recurrence.weekly,
        Recurrence.weekdays,
        Recurrence.weekends,
      ]) {
        expect(r.daySlotMinutes(9, 30), [9 * 60 + 30], reason: r.name);
      }
    });

    test('every 90 minutes from 08:00 runs to 21:30', () {
      final slots =
          Recurrence.every90m.daySlotMinutes(8, 0).map(hhmm).toList();
      expect(slots, [
        '08:00', '09:30', '11:00', '12:30', '14:00',
        '15:30', '17:00', '18:30', '20:00', '21:30',
      ]);
    });

    test('hourly and 2-hourly step by their own interval', () {
      expect(Recurrence.hourly.daySlotMinutes(20, 0).map(hhmm).toList(),
          ['20:00', '21:00', '22:00']);
      expect(Recurrence.every2h.daySlotMinutes(19, 15).map(hhmm).toList(),
          ['19:15', '21:15']);
    });

    test('never fires past 22:00 — no 3am alarms', () {
      for (final r in [
        Recurrence.hourly,
        Recurrence.every90m,
        Recurrence.every2h,
      ]) {
        final slots = r.daySlotMinutes(7, 0);
        expect(slots.last, lessThanOrEqualTo(Recurrence.dayEndMinutes),
            reason: r.name);
      }
    });

    test('a time already past the cutoff still fires once', () {
      // Otherwise picking 23:00 would silently schedule nothing at all.
      expect(Recurrence.every90m.daySlotMinutes(23, 0), [23 * 60]);
    });

    test('intervalMinutes is null for rules that fire once a day', () {
      expect(Recurrence.hourly.intervalMinutes, 60);
      expect(Recurrence.every90m.intervalMinutes, 90);
      expect(Recurrence.every2h.intervalMinutes, 120);
      expect(Recurrence.daily.intervalMinutes, isNull);
      expect(Recurrence.none.intervalMinutes, isNull);
    });
  });

  group('Recurrence.fireDays', () {
    test('weekdays = Mon–Fri, weekends = Sat–Sun', () {
      expect(Recurrence.weekdays.fireDays, [1, 2, 3, 4, 5]);
      expect(Recurrence.weekends.fireDays, [6, 7]);
    });

    test('non day-specific recurrences have no fire days', () {
      expect(Recurrence.none.fireDays, isEmpty);
      expect(Recurrence.daily.fireDays, isEmpty);
      expect(Recurrence.weekly.fireDays, isEmpty);
    });
  });

  group('Recurrence.shortLabel', () {
    test('weekly names the due date weekday', () {
      // 2026-07-15 is a Wednesday.
      expect(Recurrence.weekly.shortLabel(DateTime(2026, 7, 15)), 'Every Wed');
      // 2026-07-13 is a Monday.
      expect(Recurrence.weekly.shortLabel(DateTime(2026, 7, 13)), 'Every Mon');
    });

    test('fixed labels for the others', () {
      final day = DateTime(2026, 7, 15);
      expect(Recurrence.none.shortLabel(day), '');
      expect(Recurrence.daily.shortLabel(day), 'Every day');
      expect(Recurrence.weekdays.shortLabel(day), 'Weekdays');
      expect(Recurrence.weekends.shortLabel(day), 'Weekends');
    });
  });

  group('weekdayAbbrev', () {
    test('maps 1..7 to Mon..Sun', () {
      expect(weekdayAbbrev(1), 'Mon');
      expect(weekdayAbbrev(7), 'Sun');
      expect(weekdayAbbrev(0), '');
      expect(weekdayAbbrev(8), '');
    });
  });
}
