import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/utils/time_utils.dart';

void main() {
  group('monthYearLabel', () {
    test('names the month and year', () {
      expect(monthYearLabel(DateTime(2026, 8)), 'August 2026');
      expect(monthYearLabel(DateTime(2026, 1, 31)), 'January 2026');
      expect(monthYearLabel(DateTime(2026, 12)), 'December 2026');
    });
  });

  group('monthCells', () {
    test('is always a whole number of Monday-first weeks', () {
      for (var m = 1; m <= 12; m++) {
        final cells = monthCells(DateTime(2026, m));
        expect(cells.length % 7, 0, reason: 'month $m');
      }
    });

    test('pads the leading days so the 1st lands on its weekday', () {
      // 2026-08-01 is a Saturday → 5 blanks before it (Mon..Fri).
      final cells = monthCells(DateTime(2026, 8));
      expect(cells.take(5).every((c) => c == null), isTrue);
      expect(cells[5], DateTime(2026, 8, 1));
      expect(cells[5]!.weekday, DateTime.saturday);
    });

    test('a month starting on Monday needs no leading blanks', () {
      // 2026-06-01 is a Monday.
      final cells = monthCells(DateTime(2026, 6));
      expect(cells.first, DateTime(2026, 6, 1));
      expect(cells.first!.weekday, DateTime.monday);
    });

    test('holds every day of the month exactly once, in order', () {
      final cells = monthCells(DateTime(2026, 8));
      final days = cells.whereType<DateTime>().toList();
      expect(days, hasLength(31));
      expect(days.first.day, 1);
      expect(days.last.day, 31);
      for (var i = 1; i < days.length; i++) {
        expect(days[i].day, days[i - 1].day + 1);
      }
    });

    test('handles February in a leap and a non-leap year', () {
      expect(monthCells(DateTime(2028, 2)).whereType<DateTime>(), hasLength(29));
      expect(monthCells(DateTime(2026, 2)).whereType<DateTime>(), hasLength(28));
    });

    test('every cell belongs to the requested month', () {
      // Blanks are used rather than neighbouring months' days, so "which month
      // am I looking at" is never ambiguous.
      final cells = monthCells(DateTime(2026, 8));
      for (final c in cells.whereType<DateTime>()) {
        expect(c.month, 8);
        expect(c.year, 2026);
      }
    });
  });
}
