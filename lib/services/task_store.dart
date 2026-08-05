import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task.dart';
import 'log_service.dart';

/// The single owner of the locally-stored todo list.
///
/// The list is read and written from four places — the todo screen, the
/// shared-task mirror, the FCM handler and the WorkManager isolate — so the
/// storage key and its format migration live here rather than being repeated
/// as a `_todosKey` constant in each. Anything that touches the list must go
/// through this class, or the migration below only half-applies.
class TaskStore {
  /// Current storage key. Values are `[Task.toJson(), …]`.
  static const key = 'todos_v2';

  /// Previous key. Kept on disk untouched after migrating, as a rollback
  /// snapshot — it costs a few KB and makes a bad upgrade recoverable.
  static const legacyKey = 'todos_v1';

  /// Read the list, migrating `todos_v1` → `todos_v2` on first run.
  ///
  /// Returns an empty list when nothing is stored. A parse failure throws, so
  /// callers can tell "no tasks" apart from "could not read tasks" — silently
  /// returning empty here would look exactly like data loss to the user.
  static Future<List<Task>> load(SharedPreferences prefs) async {
    final raw = prefs.getString(key);
    if (raw != null) return decode(raw);

    final legacy = prefs.getString(legacyKey);
    if (legacy == null) return [];

    final migrated = decode(legacy);
    await save(prefs, migrated);
    LogService.i('taskstore',
        'migrated ${migrated.length} task(s) from $legacyKey to $key');
    return migrated;
  }

  /// Persist the list. Returns the JSON written, so callers that also mirror
  /// it (the Firestore todo backup) don't have to re-encode.
  static Future<String> save(SharedPreferences prefs, List<Task> tasks) async {
    final json = encode(tasks);
    await prefs.setString(key, json);
    return json;
  }

  /// Parse a stored list. Accepts both storage formats — see [Task.fromJson].
  static List<Task> decode(String raw) => (jsonDecode(raw) as List)
      .map((e) => Task.fromJson(e as Map))
      .toList();

  static String encode(List<Task> tasks) =>
      jsonEncode(tasks.map((t) => t.toJson()).toList());
}
