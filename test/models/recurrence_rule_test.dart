import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/recurrence.dart';
import 'package:chatapp/models/recurrence_rule.dart';

void main() {
  group('legacy bridge', () {
    test('every legacy value round-trips through the rule', () {
      for (final r in Recurrence.values) {
        expect(RecurrenceRule.fromLegacy(r).toLegacy(), r,
            reason: 'round-trip failed for ${r.name}');
      }
    });

    test('weekdays and weekends map onto BYDAY sets', () {
      expect(RecurrenceRule.fromLegacy(Recurrence.weekdays).byWeekday,
          [1, 2, 3, 4, 5]);
      expect(RecurrenceRule.fromLegacy(Recurrence.weekends).byWeekday, [6, 7]);
    });

    test('weekly carries no BYDAY — it follows the start date', () {
      expect(RecurrenceRule.fromLegacy(Recurrence.weekly).byWeekday, isEmpty);
    });

    test('rules the enum cannot express return null, never none', () {
      // The critical property: a caller must be able to tell "does not repeat"
      // apart from "repeats in a way I cannot schedule". Conflating them is the
      // silent-downgrade bug fixed in #96.
      final everyThreeDays = RecurrenceRule(freq: Freq.daily, interval: 3);
      final monthly = RecurrenceRule(freq: Freq.monthly);
      final bounded = RecurrenceRule(
          freq: Freq.weekly, until: DateTime(2030, 1, 1));
      final oddDays =
          RecurrenceRule(freq: Freq.weekly, byWeekday: const [1, 3]);

      for (final r in [everyThreeDays, monthly, bounded, oddDays]) {
        expect(r.toLegacy(), isNull, reason: r.storage);
        expect(r.isNativelySchedulable, isFalse);
      }
      expect(RecurrenceRule.none.toLegacy(), Recurrence.none);
      expect(RecurrenceRule.none.isNativelySchedulable, isTrue);
    });
  });

  group('storage', () {
    test('none serializes to null so no field is stored', () {
      expect(RecurrenceRule.none.storage, isNull);
      expect(RecurrenceRule.none.repeats, isFalse);
    });

    test('serializes an RRULE string', () {
      expect(RecurrenceRule(freq: Freq.daily).storage, 'FREQ=DAILY');
      expect(RecurrenceRule(freq: Freq.weekly, interval: 2).storage,
          'FREQ=WEEKLY;INTERVAL=2');
      expect(
          RecurrenceRule(freq: Freq.weekly, byWeekday: const [1, 3]).storage,
          'FREQ=WEEKLY;BYDAY=MO,WE');
      expect(RecurrenceRule(freq: Freq.monthly, count: 5).storage,
          'FREQ=MONTHLY;COUNT=5');
      expect(
          RecurrenceRule(freq: Freq.yearly, until: DateTime(2030, 4, 5, 9, 30))
              .storage,
          'FREQ=YEARLY;UNTIL=20300405T093000');
    });

    test('round-trips every shape through storage', () {
      final rules = [
        RecurrenceRule.none,
        RecurrenceRule(freq: Freq.daily),
        RecurrenceRule(freq: Freq.daily, interval: 3),
        RecurrenceRule(freq: Freq.weekly, byWeekday: const [1, 3, 5]),
        RecurrenceRule(freq: Freq.weekly, interval: 2, byWeekday: const [6, 7]),
        RecurrenceRule(freq: Freq.monthly, count: 12),
        RecurrenceRule(freq: Freq.yearly, until: DateTime(2031, 12, 25, 8, 0)),
      ];
      for (final r in rules) {
        expect(RecurrenceRule.fromStorage(r.storage), r,
            reason: 'round-trip failed for ${r.storage}');
      }
    });

    test('reads the legacy enum names stored by older builds', () {
      // Existing todos and reminder docs hold "daily"/"weekdays"/… — they must
      // keep working without a data migration.
      expect(RecurrenceRule.fromStorage('daily'),
          RecurrenceRule.fromLegacy(Recurrence.daily));
      expect(RecurrenceRule.fromStorage('weekdays'),
          RecurrenceRule.fromLegacy(Recurrence.weekdays));
      expect(RecurrenceRule.fromStorage('weekends'),
          RecurrenceRule.fromLegacy(Recurrence.weekends));
      expect(RecurrenceRule.fromStorage('none'), RecurrenceRule.none);
    });

    test('null, empty and unparseable input become none', () {
      for (final s in [null, '', 'nonsense', 'FREQ=NOPE']) {
        expect(RecurrenceRule.fromStorage(s), RecurrenceRule.none, reason: '$s');
      }
    });

    test('BYDAY is normalised — order and duplicates do not change identity',
        () {
      final a = RecurrenceRule(freq: Freq.weekly, byWeekday: const [5, 1, 3, 1]);
      final b = RecurrenceRule(freq: Freq.weekly, byWeekday: const [1, 3, 5]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.byWeekday, [1, 3, 5]);
    });

    test('an interval below 1 is clamped', () {
      expect(RecurrenceRule(freq: Freq.daily, interval: 0).interval, 1);
    });

    test('out-of-range weekdays are dropped', () {
      expect(RecurrenceRule(freq: Freq.weekly, byWeekday: const [0, 8, 3])
          .byWeekday, [3]);
    });
  });

  group('labels', () {
    test('legacy-equivalent rules keep the existing wording', () {
      expect(RecurrenceRule.none.label, 'Does not repeat');
      expect(RecurrenceRule.fromLegacy(Recurrence.daily).label, 'Every day');
      expect(RecurrenceRule.fromLegacy(Recurrence.weekdays).label,
          'Weekdays (Mon–Fri)');
    });

    test('a weekly rule names the start date weekday', () {
      // 2030-01-07 is a Monday.
      expect(
          RecurrenceRule.fromLegacy(Recurrence.weekly)
              .shortLabel(DateTime(2030, 1, 7)),
          'Every Mon');
    });

    test('richer rules get a generated label', () {
      expect(RecurrenceRule(freq: Freq.daily, interval: 3).label,
          'Every 3 days');
      expect(RecurrenceRule(freq: Freq.monthly).label, 'Every month');
      expect(
          RecurrenceRule(freq: Freq.weekly, byWeekday: const [1, 3])
              .shortLabel(DateTime(2030, 1, 7)),
          'Mon, Wed');
    });
  });
}
