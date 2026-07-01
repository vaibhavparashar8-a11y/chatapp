import 'dart:developer' as dev;
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
  static const _tag = 'NotificationService';

  static Future<void> init() async {
    if (testMode || _initialized) return;
    try {
      tz.initializeTimeZones();
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));
      _initialized = true;
      dev.log('init: success', name: _tag);
    } catch (e, st) {
      dev.log('init: FAILED — $e', name: _tag, error: e, stackTrace: st);
      rethrow;
    }
  }

  static Future<bool> scheduleReminder({
    required int id,
    required String title,
    required DateTime scheduledTime,
  }) async {
    if (testMode) return true;

    if (!_initialized) {
      try {
        await init();
      } catch (e) {
        dev.log('scheduleReminder: init failed — $e', name: _tag);
        return false;
      }
    }

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    try {
      await androidImpl?.requestNotificationsPermission();
      dev.log('requestNotificationsPermission: done', name: _tag);
    } catch (e) {
      dev.log('requestNotificationsPermission: threw — $e', name: _tag);
    }

    AndroidScheduleMode scheduleMode;
    try {
      final canExact =
          await androidImpl?.canScheduleExactNotifications() ?? true;
      dev.log('canScheduleExactNotifications: $canExact', name: _tag);
      scheduleMode = canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexact;
    } catch (e) {
      dev.log(
          'canScheduleExactNotifications: threw — $e — defaulting to exact',
          name: _tag);
      scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;
    }
    dev.log('scheduleMode chosen: $scheduleMode', name: _tag);

    final utc = scheduledTime.toUtc();
    var tzScheduled = tz.TZDateTime(
      tz.UTC, utc.year, utc.month, utc.day, utc.hour, utc.minute,
    );
    final nowUtc = tz.TZDateTime.now(tz.UTC);
    dev.log(
        'scheduledTime (local)=$scheduledTime  tzScheduled(UTC)=$tzScheduled  nowUtc=$nowUtc',
        name: _tag);

    if (tzScheduled.isBefore(nowUtc)) {
      tzScheduled = nowUtc.add(const Duration(seconds: 5));
      dev.log('past-time guard: rescheduled to $tzScheduled', name: _tag);
    }

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Reminders for your to-do tasks',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    try {
      await _plugin.zonedSchedule(
        id, 'Task Reminder', title, tzScheduled, details,
        androidScheduleMode: scheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      dev.log('zonedSchedule: SUCCESS (mode=$scheduleMode id=$id)', name: _tag);
      return true;
    } catch (e, st) {
      dev.log('zonedSchedule: FAILED (mode=$scheduleMode) — $e',
          name: _tag, error: e, stackTrace: st);

      if (scheduleMode == AndroidScheduleMode.exactAllowWhileIdle) {
        dev.log('retrying with AndroidScheduleMode.inexact', name: _tag);
        try {
          await _plugin.zonedSchedule(
            id, 'Task Reminder', title, tzScheduled, details,
            androidScheduleMode: AndroidScheduleMode.inexact,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
          );
          dev.log('zonedSchedule: SUCCESS (inexact fallback id=$id)',
              name: _tag);
          return true;
        } catch (e2, st2) {
          dev.log('zonedSchedule: inexact fallback ALSO FAILED — $e2',
              name: _tag, error: e2, stackTrace: st2);
        }
      }
      return false;
    }
  }

  static Future<void> cancelReminder(int id) async {
    if (testMode) return;
    try {
      await _plugin.cancel(id);
      dev.log('cancelReminder: cancelled id=$id', name: _tag);
    } catch (e) {
      dev.log('cancelReminder: failed — $e', name: _tag);
    }
  }
}
