import 'dart:developer' as dev;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../models/recurrence.dart';
import 'log_service.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  // Set to true in widget/unit tests to skip all platform-channel calls.
  static bool testMode = false;

  static const _channelId = 'task_reminders';
  static const _channelName = 'Task Reminders';
  static const _tag = 'NotificationService';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Reminders for your to-do tasks',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

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

  /// Schedule a reminder. With [recurrence] other than [Recurrence.none] the
  /// notification repeats natively (the OS/AlarmManager owns the repeat, so it
  /// survives the app being killed and reboot). Weekdays/weekends schedule one
  /// weekly notification per day, under ids derived from [id]; cancel them all
  /// with [cancelReminderGroup].
  static Future<bool> scheduleReminder({
    required int id,
    required String title,
    required DateTime scheduledTime,
    Recurrence recurrence = Recurrence.none,
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

    // One entry per notification to schedule. A one-shot fires once at
    // tzScheduled; repeating ones use matchDateTimeComponents so the OS repeats
    // them, computing the next occurrence of the picked time / weekday.
    final h = scheduledTime.hour;
    final m = scheduledTime.minute;
    final List<({int id, tz.TZDateTime when, DateTimeComponents? match})> jobs;
    switch (recurrence) {
      case Recurrence.none:
        jobs = [(id: id, when: tzScheduled, match: null)];
      case Recurrence.daily:
        jobs = [
          (
            id: id,
            when: _nextInstanceOfTime(h, m),
            match: DateTimeComponents.time,
          )
        ];
      case Recurrence.weekly:
        jobs = [
          (
            id: id,
            when: _nextInstanceOfWeekdayTime(scheduledTime.weekday, h, m),
            match: DateTimeComponents.dayOfWeekAndTime,
          )
        ];
      case Recurrence.weekdays:
      case Recurrence.weekends:
        jobs = [
          for (final wd in recurrence.fireDays)
            (
              id: _weekdayNotifId(id, wd),
              when: _nextInstanceOfWeekdayTime(wd, h, m),
              match: DateTimeComponents.dayOfWeekAndTime,
            )
        ];
    }

    var allOk = true;
    for (final job in jobs) {
      final ok =
          await _zoned(job.id, title, job.when, scheduleMode, job.match);
      allOk = allOk && ok;
    }
    return allOk;
  }

  /// One zonedSchedule call with the exact→inexact retry the app relies on.
  static Future<bool> _zoned(int id, String title, tz.TZDateTime when,
      AndroidScheduleMode mode, DateTimeComponents? match) async {
    try {
      await _plugin.zonedSchedule(
        id,
        'Task Reminder',
        title,
        when,
        _details,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: match,
      );
      dev.log('zonedSchedule: SUCCESS (mode=$mode id=$id match=$match)',
          name: _tag);
      return true;
    } catch (e, st) {
      dev.log('zonedSchedule: FAILED (mode=$mode) — $e',
          name: _tag, error: e, stackTrace: st);
      LogService.e(_tag, 'zonedSchedule failed (mode=$mode): $e');

      if (mode == AndroidScheduleMode.exactAllowWhileIdle) {
        dev.log('retrying with AndroidScheduleMode.inexact', name: _tag);
        try {
          await _plugin.zonedSchedule(
            id,
            'Task Reminder',
            title,
            when,
            _details,
            androidScheduleMode: AndroidScheduleMode.inexact,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: match,
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

  /// Next occurrence of [hour]:[minute] in local time (today if still ahead,
  /// else tomorrow).
  static tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var when =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    return when;
  }

  /// Next occurrence of [weekday] (1=Mon..7=Sun) at [hour]:[minute].
  static tz.TZDateTime _nextInstanceOfWeekdayTime(
      int weekday, int hour, int minute) {
    var when = _nextInstanceOfTime(hour, minute);
    while (when.weekday != weekday) {
      when = when.add(const Duration(days: 1));
    }
    return when;
  }

  /// Distinct, positive notification id for one weekday of a multi-day
  /// recurrence, derived from the task's base id.
  static int _weekdayNotifId(int baseId, int weekday) =>
      (baseId.abs() % 100000000) * 10 + weekday;

  static Future<void> cancelReminder(int id) async {
    if (testMode) return;
    try {
      await _plugin.cancel(id);
      dev.log('cancelReminder: id=$id', name: _tag);
    } catch (e) {
      dev.log('cancelReminder: failed — $e', name: _tag);
    }
  }

  /// Cancel a reminder that may be recurring: the base [baseId] plus every
  /// weekday-derived id a weekdays/weekends schedule could have used. Cheap
  /// (8 cancels) and safe regardless of the actual recurrence.
  static Future<void> cancelReminderGroup(int baseId) async {
    if (testMode) return;
    await cancelReminder(baseId);
    for (var wd = 1; wd <= 7; wd++) {
      await cancelReminder(_weekdayNotifId(baseId, wd));
    }
  }

  /// Show the daily task digest now — a single notification whose body is a
  /// multi-line ☐ checklist (BigText so it expands). Called by the background
  /// worker at the user's chosen time; see [DigestService].
  static Future<void> showDigest({
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
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Reminders for your to-do tasks',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(body, contentTitle: title),
      ),
    );
    try {
      await _plugin.show(id, title, body, details);
      dev.log('showDigest: id=$id', name: _tag);
    } catch (e) {
      dev.log('showDigest: FAILED — $e', name: _tag);
      LogService.e(_tag, 'showDigest failed: $e');
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
