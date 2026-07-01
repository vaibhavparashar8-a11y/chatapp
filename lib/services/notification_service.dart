import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  // Set to true in widget/unit tests to skip all platform-channel calls.
  static bool testMode = false;

  static const _channelId = 'task_reminders';
  static const _channelName = 'Task Reminders';

  static Future<void> init() async {
    if (testMode || _initialized) return;
    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    _initialized = true;
    // Permissions are requested lazily in scheduleReminder() so that dialogs
    // only appear after the Flutter Activity is fully running (not in main()).
  }

  /// Schedules a local notification at [scheduledTime] (local device time).
  ///
  /// Returns true if the notification was successfully scheduled.
  /// Returns false if the "Alarms & reminders" exact-alarm permission is not
  /// yet granted — in that case the Settings page is opened for the user to
  /// approve, and the caller should prompt them to re-set the reminder.
  static Future<bool> scheduleReminder({
    required int id,
    required String title,
    required DateTime scheduledTime,
  }) async {
    if (testMode) return true;
    if (!_initialized) await init();

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    // Request POST_NOTIFICATIONS (Android 13+). No-op if already granted or
    // on older Android — safe to call every time.
    await androidImpl?.requestNotificationsPermission();

    // Check SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM (Android 12+).
    // canScheduleExactNotifications() returns null on Android < 12 (no
    // restriction exists there), so we treat null as "yes".
    final canExact =
        await androidImpl?.canScheduleExactNotifications() ?? true;
    if (!canExact) {
      // Open the "Alarms & reminders" settings page so the user can grant it.
      await androidImpl?.requestExactAlarmsPermission();
      return false; // caller must re-try after the user grants the permission
    }

    // Convert local DateTime to UTC so TZDateTime fires at the exact moment.
    final utc = scheduledTime.toUtc();
    final tzScheduled = tz.TZDateTime(
      tz.UTC, utc.year, utc.month, utc.day, utc.hour, utc.minute,
    );

    await _plugin.zonedSchedule(
      id,
      'Task Reminder',
      title,
      tzScheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Reminders for your to-do tasks',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
    return true;
  }

  static Future<void> cancelReminder(int id) async {
    if (testMode) return;
    await _plugin.cancel(id);
  }
}
