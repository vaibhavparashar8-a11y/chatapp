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
