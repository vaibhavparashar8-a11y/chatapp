import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/recurrence.dart';
import 'package:chatapp/services/notification_service.dart';

void main() {
  setUp(() {
    NotificationService.testMode = true;
    NotificationService.debugCancelled.clear();
    NotificationService.debugScheduled.clear();
  });

  tearDown(() => NotificationService.testMode = false);

  group('cancelReminderGroup covers every id family', () {
    // A reminder is scheduled under one of three id families depending on its
    // recurrence, and the caller clearing it usually no longer knows which one
    // it used. Missing a family leaves alarms firing after the user cleared
    // the reminder — an "every 90 minutes" one would then nag all day.
    const baseId = 987654321;

    test('cancels the base id itself (one-shot / daily / weekly)', () async {
      await NotificationService.cancelReminderGroup(baseId);
      expect(NotificationService.debugCancelled, contains(baseId));
    });

    test('cancels all seven weekday ids (weekdays / weekends)', () async {
      await NotificationService.cancelReminderGroup(baseId);
      // Same derivation as the scheduler: (base % 1e8) * 10 + weekday.
      for (var wd = 1; wd <= 7; wd++) {
        expect(NotificationService.debugCancelled,
            contains((baseId.abs() % 100000000) * 10 + wd),
            reason: 'weekday $wd');
      }
    });

    test('cancels every interval slot id', () async {
      await NotificationService.cancelReminderGroup(baseId);
      // Same derivation as the scheduler: (base % 1e6) * 1000 + 100 + slot.
      for (var i = 0; i < NotificationService.maxDailySlots; i++) {
        expect(NotificationService.debugCancelled,
            contains((baseId.abs() % 1000000) * 1000 + 100 + i),
            reason: 'slot $i');
      }
    });

    test('covers the widest interval rule the picker offers', () {
      // Hourly from midnight wants the most slots of anything selectable.
      final slots = Recurrence.hourly.daySlotMinutes(0, 0);
      expect(slots.length, lessThanOrEqualTo(NotificationService.maxDailySlots),
          reason: 'every scheduled slot must be cancellable');
    });
  });
}
