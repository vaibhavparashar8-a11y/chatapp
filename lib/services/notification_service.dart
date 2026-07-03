import 'dart:developer' as dev;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'log_service.dart';

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
      // Load timezone database and set the device's local timezone — required
      // by flutter_local_notifications before calling zonedSchedule().
      tz.initializeTimeZones();
      try {
        final tzInfo = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
        dev.log('timezone: set to ${tzInfo.identifier}', name: _tag);
      } catch (e) {
        // Fallback: leave tz.local as UTC — alarm will still fire, just labeled UTC.
        dev.log('timezone: could not resolve local timezone — $e', name: _tag);
      }

      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(
        const InitializationSettings(android: android),
        // Required in v17+ — without this, tapping a notification while the
        // app is in the foreground can throw an unhandled PlatformException.
        onDidReceiveNotificationResponse: (details) {
          dev.log('onDidReceiveNotificationResponse: id=${details.id}', name: _tag);
        },
      );
      _initialized = true;
      dev.log('init: success', name: _tag);
    } catch (e, st) {
      dev.log('init: FAILED — $e', name: _tag, error: e, stackTrace: st);
      LogService.e(_tag, 'init failed: $e');
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
        LogService.e(_tag, 'scheduleReminder: init failed: $e');
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
    dev.log('scheduleMode: $scheduleMode', name: _tag);

    // Convert the user's picked local DateTime to a TZDateTime in the
    // device's local timezone. This is the approach recommended by the
    // flutter_local_notifications docs and is the most reliable on Android.
    tz.TZDateTime tzScheduled;
    try {
      tzScheduled = tz.TZDateTime.from(scheduledTime, tz.local);
    } catch (e) {
      // tz.local not set (shouldn't happen after init, but defensive fallback).
      dev.log('TZDateTime.from failed — $e — using UTC offset', name: _tag);
      final utc = scheduledTime.toUtc();
      tzScheduled = tz.TZDateTime(
          tz.UTC, utc.year, utc.month, utc.day, utc.hour, utc.minute);
    }

    // Guard: if the picked time is already in the past, fire in 5 s instead
    // of letting zonedSchedule throw or silently drop the alarm.
    final nowLocal = tz.TZDateTime.now(tz.local);
    dev.log(
        'scheduledTime=$scheduledTime  tzScheduled=$tzScheduled  now=$nowLocal',
        name: _tag);
    if (tzScheduled.isBefore(nowLocal)) {
      tzScheduled = nowLocal.add(const Duration(seconds: 5));
      dev.log('past-time guard: rescheduled to $tzScheduled', name: _tag);
    }

    const details = NotificationDetails(
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
        id,
        'Task Reminder',
        title,
        tzScheduled,
        details,
        androidScheduleMode: scheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      dev.log('zonedSchedule: SUCCESS (mode=$scheduleMode id=$id)', name: _tag);
      return true;
    } catch (e, st) {
      dev.log('zonedSchedule: FAILED (mode=$scheduleMode) — $e',
          name: _tag, error: e, stackTrace: st);
      LogService.e(_tag, 'zonedSchedule failed (mode=$scheduleMode): $e');

      if (scheduleMode == AndroidScheduleMode.exactAllowWhileIdle) {
        dev.log('retrying with AndroidScheduleMode.inexact', name: _tag);
        try {
          await _plugin.zonedSchedule(
            id,
            'Task Reminder',
            title,
            tzScheduled,
            details,
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
          LogService.e(_tag, 'zonedSchedule inexact fallback failed: $e2');
        }
      }
      return false;
    }
  }

  static Future<void> cancelReminder(int id) async {
    if (testMode) return;
    try {
      await _plugin.cancel(id);
      dev.log('cancelReminder: id=$id', name: _tag);
    } catch (e) {
      dev.log('cancelReminder: failed — $e', name: _tag);
    }
  }

  /// Show an immediate (non-scheduled) notification — used when an FCM
  /// push arrives to alert the user right away regardless of app state.
  static Future<void> showNow({
    required int id,
    required String title,
    required String body,
  }) async {
    if (testMode) return;
    if (!_initialized) {
      try {
        await init();
      } catch (_) {
        return;
      }
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Reminders for your to-do tasks',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    try {
      await _plugin.show(id, title, body, details);
      dev.log('showNow: id=$id title=$title', name: _tag);
    } catch (e) {
      dev.log('showNow: FAILED — $e', name: _tag);
    }
  }
}
