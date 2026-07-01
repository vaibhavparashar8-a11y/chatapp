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
  }

  /// Schedules a local notification at [scheduledTime] (local device time).
  static Future<void> scheduleReminder({
    required int id,
    required String title,
    required DateTime scheduledTime,
  }) async {
    if (testMode) return;
    if (!_initialized) await init();

    // Convert local time to UTC so tz.TZDateTime fires at the correct moment
    // regardless of which IANA timezone the device is in.
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
  }

  static Future<void> cancelReminder(int id) async {
    if (testMode) return;
    await _plugin.cancel(id);
  }
}
