part of '../todo_screen.dart';

// ── Reminder re-arming ───────────────────────────────────────────────────────
// Android clears an app's scheduled AlarmManager alarms when the APK is
// updated. The boot receiver only restores them on reboot, and nothing else
// re-schedules local reminders — so without this, updating the app would
// silently drop every pending reminder until the user re-set each one.
// Re-arming on launch closes that gap. It's an extension (reads state, calls
// the service, no setState) so it stays analyzer-clean.

extension _TodoReminders on _TodoScreenState {
  /// Re-schedule every still-pending local reminder with the OS. Called once
  /// per app launch from initState. Safe to run repeatedly: each schedule
  /// overwrites the same notification id, and already-elapsed one-shot
  /// reminders are skipped so nothing re-fires.
  Future<void> _rearmReminders() async {
    final now = DateTime.now();
    for (final todo in _todos) {
      final due = todo.dueDate;
      if (due == null || todo.done) continue;
      // A one-shot whose time has passed already fired — leave it. Recurring
      // reminders always re-arm; their future occurrences keep firing.
      if (todo.recurrence == Recurrence.none && !due.isAfter(now)) continue;
      // Clear any stale schedule (incl. weekday-group ids) before re-arming.
      await NotificationService.cancelReminderGroup(todo.id.hashCode);
      await NotificationService.scheduleReminder(
        id: todo.id.hashCode,
        title: todo.title,
        scheduledTime: due,
        recurrence: todo.recurrence,
      );
    }
  }
}
