import 'package:shared_preferences/shared_preferences.dart';
import '../models/task.dart';
import 'log_service.dart';
import 'notification_service.dart';
import 'task_store.dart';

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

  /// Titles of not-done tasks starting on [day]. Pure + testable.
  ///
  /// Reads through [Task.fromJson], so both storage formats work — v2's
  /// `start` and v1's `dueDate`.
  static List<String> titlesFor(String? todosJson, DateTime day) {
    if (todosJson == null) return [];
    final List<Task> tasks;
    try {
      tasks = TaskStore.decode(todosJson);
    } catch (e) {
      LogService.w('digest', 'could not parse stored todos: $e');
      return [];
    }
    final out = <String>[];
    for (final t in tasks) {
      if (t.done) continue;
      final d = t.start;
      if (d == null) continue;
      if (d.year == day.year && d.month == day.month && d.day == day.day) {
        final title = t.title.trim();
        out.add(title.isEmpty ? 'Task' : title);
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

    // Read the migrated list if present, else the pre-migration one — the
    // worker can run before the screen has ever migrated it.
    final body = buildBody(
        prefs.getString(TaskStore.key) ?? prefs.getString(TaskStore.legacyKey),
        now);
    await NotificationService.showDigest(
      id: digestNotificationId,
      title: "Today's tasks",
      body: body,
    );
    await prefs.setString(_lastShownKey, today);
  }
}
