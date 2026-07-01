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
  ///
  /// Returns true when the alarm was successfully registered (with exact or
  /// inexact timing), false only if the underlying platform call threw.
  ///
  /// Exact-alarm behaviour by Android version:
  ///   • Android 13+ (API 33+): USE_EXACT_ALARM in manifest is auto-granted —
  ///     exact scheduling works without any user interaction.
  ///   • Android 12 (API 31-32): SCHEDULE_EXACT_ALARM needs user approval.
  ///     If not yet granted, falls back to inexact mode so the notification
  ///     still fires (may arrive a few minutes late) — never opens Settings,
  ///     never crashes.
  ///   • Android ≤ 11: exact scheduling always allowed, no permission needed.
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

    // Request POST_NOTIFICATIONS (Android 13+). No-op on older versions or if
    // already granted. Swallowed — a denied permission just means the
    // notification won't be visible but we still register the alarm.
    try {
      await androidImpl?.requestNotificationsPermission();
    } catch (_) {}

    // Pick the best available schedule mode without opening Settings or crashing.
    AndroidScheduleMode scheduleMode;
    try {
      final canExact =
          await androidImpl?.canScheduleExactNotifications() ?? true;
      scheduleMode = canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexact;
    } catch (_) {
      // canScheduleExactNotifications threw (older OS / plugin version) —
      // assume exact is fine; if it isn't, the catch below handles it.
      scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;
    }

    // Build the TZDateTime in UTC so the alarm fires at the correct local moment.
    final utc = scheduledTime.toUtc();
    var tzScheduled = tz.TZDateTime(
      tz.UTC, utc.year, utc.month, utc.day, utc.hour, utc.minute,
    );

    // Guard: if the picked time is already in the past, fire in 5 s instead
    // of letting zonedSchedule throw or silently drop the alarm.
    final nowUtc = tz.TZDateTime.now(tz.UTC);
    if (tzScheduled.isBefore(nowUtc)) {
      tzScheduled = nowUtc.add(const Duration(seconds: 5));
    }

    try {
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
        androidScheduleMode: scheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      return true;
    } catch (_) {
      // zonedSchedule threw (e.g. exact mode rejected on Android 12 without
      // the user-granted SCHEDULE_EXACT_ALARM) — retry once with inexact.
      if (scheduleMode == AndroidScheduleMode.exactAllowWhileIdle) {
        try {
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
            androidScheduleMode: AndroidScheduleMode.inexact,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
          );
          return true;
        } catch (_) {}
      }
      return false;
    }
  }

  static Future<void> cancelReminder(int id) async {
    if (testMode) return;
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }
}
