import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

/// On-device "daily task summary" preferences.
class DigestPrefs {
  final bool enabled;
  final int hour; // 0–23, local wall clock
  final int minute; // 0–59
  const DigestPrefs({
    required this.enabled,
    required this.hour,
    required this.minute,
  });

  factory DigestPrefs.defaults() =>
      const DigestPrefs(enabled: false, hour: 6, minute: 30);
}

/// A free, fully on-device daily digest: once a day, at or after the user's
/// chosen local time, a single local notification lists the day's tasks as a
/// ☐ checklist. Driven by the WorkManager background worker (which already runs
/// ~every 15 min), so it fires even when the app is killed — no server, no
/// external account. The per-task reminders remain separate local
/// notifications (see [NotificationService.scheduleReminder]).
class DigestService {
  static bool testMode = false;

  static const _enabledKey = 'digest_enabled';
  static const _hourKey = 'digest_hour';
  static const _minuteKey = 'digest_minute';
  static const _lastShownKey = 'digest_last_shown'; // 'yyyy-mm-dd', local
  static const _todosKey = 'todos_v1';

  /// Fixed notification id for the daily digest (never collides with reminder
  /// ids, which are task-id/doc-id hashes).
  static const digestNotificationId = 909090;

  static DigestPrefs _read(SharedPreferences prefs) => DigestPrefs(
        enabled: prefs.getBool(_enabledKey) ?? false,
        hour: prefs.getInt(_hourKey) ?? 6,
        minute: prefs.getInt(_minuteKey) ?? 30,
      );

  /// Load the saved settings (or defaults) for the settings UI.
  static Future<DigestPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _read(prefs);
  }

  /// Persist settings. Clears the "already shown today" guard so a re-enable or
  /// a time change can still fire today.
  static Future<void> save(DigestPrefs p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, p.enabled);
    await prefs.setInt(_hourKey, p.hour);
    await prefs.setInt(_minuteKey, p.minute);
    await prefs.remove(_lastShownKey);
  }

  /// Titles of not-done tasks whose dueDate falls on [day]. Pure + testable.
  static List<String> titlesFor(String? todosJson, DateTime day) {
    if (todosJson == null) return [];
    final List list;
    try {
      list = jsonDecode(todosJson) as List;
    } catch (_) {
      return [];
    }
    final out = <String>[];
    for (final e in list) {
      final m = e as Map;
      if (m['done'] as bool? ?? false) continue;
      final due = m['dueDate'] as String?;
      if (due == null) continue;
      final DateTime d;
      try {
        d = DateTime.parse(due);
      } catch (_) {
        continue;
      }
      if (d.year == day.year && d.month == day.month && d.day == day.day) {
        final title = (m['title'] as String?)?.trim();
        out.add(title == null || title.isEmpty ? 'Task' : title);
      }
    }
    return out;
  }

  /// The notification body: a ☐ checklist, or a friendly empty message. Pure.
  static String buildBody(String? todosJson, DateTime day) {
    final titles = titlesFor(todosJson, day);
    if (titles.isEmpty) return 'No tasks scheduled today. 🎉';
    return titles.map((t) => '☐ $t').join('\n');
  }

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Show the digest at most once per day, at or after the configured local
  /// time. Called from the background worker; the last-shown-date guard means a
  /// missed slot still catches up later the same day, and never double-fires.
  static Future<void> maybeShowDigest(SharedPreferences prefs) async {
    if (testMode) return;
    final p = _read(prefs);
    if (!p.enabled) return;

    final now = DateTime.now();
    final today = _dateStr(now);
    if (prefs.getString(_lastShownKey) == today) return; // already shown today

    final nowMinutes = now.hour * 60 + now.minute;
    final cfgMinutes = p.hour * 60 + p.minute;
    if (nowMinutes < cfgMinutes) return; // not time yet

    final body = buildBody(prefs.getString(_todosKey), now);
    await NotificationService.showDigest(
      id: digestNotificationId,
      title: "Today's tasks",
      body: body,
    );
    await prefs.setString(_lastShownKey, today);
  }
}
