import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/models/recurrence.dart';
import 'package:chatapp/models/recurrence_rule.dart';
import 'package:chatapp/models/task.dart';
import 'package:chatapp/services/task_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  group('load', () {
    test('returns an empty list when nothing is stored', () async {
      final prefs = await prefsWith({});
      expect(await TaskStore.load(prefs), isEmpty);
    });

    test('reads the current format', () async {
      final task = Task('t1', 'Task', start: DateTime(2030, 1, 1, 9));
      final prefs = await prefsWith({TaskStore.key: TaskStore.encode([task])});
      final loaded = await TaskStore.load(prefs);
      expect(loaded.single.title, 'Task');
      expect(loaded.single.start, DateTime(2030, 1, 1, 9));
    });

    test('a corrupt list throws rather than reporting "no tasks"', () async {
      // Silently returning [] here is indistinguishable from data loss to the
      // user — callers need to be able to tell the two apart.
      final prefs = await prefsWith({TaskStore.key: 'not json'});
      expect(() => TaskStore.load(prefs), throwsA(anything));
    });
  });

  group('v1 → v2 migration', () {
    test('migrates a legacy list and writes it back in the new format',
        () async {
      final prefs = await prefsWith({
        TaskStore.legacyKey: jsonEncode([
          {
            'id': 't1',
            'title': 'Old task',
            'done': false,
            'dueDate': DateTime(2030, 1, 1, 9, 0).toIso8601String(),
            'recurrence': 'weekdays',
            'sharedId': 'doc1',
            'subtasks': [
              {'id': 's1', 'title': 'Step', 'done': true}
            ],
          }
        ]),
      });

      final loaded = await TaskStore.load(prefs);

      expect(loaded.single.title, 'Old task');
      expect(loaded.single.start, DateTime(2030, 1, 1, 9, 0));
      expect(loaded.single.recurrence,
          RecurrenceRule.fromLegacy(Recurrence.weekdays));
      expect(loaded.single.sharedId, 'doc1');
      expect(loaded.single.subtasks.single.done, isTrue);

      // Written back under the new key, in the new format.
      final stored =
          jsonDecode(prefs.getString(TaskStore.key)!) as List;
      expect(stored.single['start'], DateTime(2030, 1, 1, 9, 0).toIso8601String());
      expect(stored.single['rrule'], 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR');
      expect(stored.single.containsKey('dueDate'), isFalse);
    });

    test('leaves the legacy key in place as a rollback snapshot', () async {
      final legacy = jsonEncode([
        {'id': 't1', 'title': 'Old', 'done': false, 'subtasks': <dynamic>[]}
      ]);
      final prefs = await prefsWith({TaskStore.legacyKey: legacy});
      await TaskStore.load(prefs);
      expect(prefs.getString(TaskStore.legacyKey), legacy);
    });

    test('is idempotent — a second load does not re-migrate', () async {
      final prefs = await prefsWith({
        TaskStore.legacyKey: jsonEncode([
          {'id': 't1', 'title': 'Old', 'done': false, 'subtasks': <dynamic>[]}
        ]),
      });
      await TaskStore.load(prefs);
      // Change v1 behind our back; it must be ignored now that v2 exists.
      await prefs.setString(
          TaskStore.legacyKey,
          jsonEncode([
            {'id': 't2', 'title': 'Ignored', 'done': false, 'subtasks': <dynamic>[]}
          ]));
      final second = await TaskStore.load(prefs);
      expect(second.single.title, 'Old');
    });

    test('the migrated list never loses a task', () async {
      final prefs = await prefsWith({
        TaskStore.legacyKey: jsonEncode([
          for (var i = 0; i < 25; i++)
            {'id': 't$i', 'title': 'Task $i', 'done': i.isEven,
              'subtasks': <dynamic>[]}
        ]),
      });
      final loaded = await TaskStore.load(prefs);
      expect(loaded, hasLength(25));
      expect(loaded.map((t) => t.title), contains('Task 24'));
    });
  });

  group('save', () {
    test('returns the JSON it wrote, so callers can mirror it', () async {
      final prefs = await prefsWith({});
      final json = await TaskStore.save(prefs, [Task('t1', 'Task')]);
      expect(json, prefs.getString(TaskStore.key));
      expect(jsonDecode(json), hasLength(1));
    });

    test('a save → load round-trip preserves the list', () async {
      final prefs = await prefsWith({});
      final tasks = [
        Task('t1', 'One', start: DateTime(2030, 2, 2, 8)),
        Task('t2', 'Two', done: true, reminderDocId: 'doc2'),
      ];
      await TaskStore.save(prefs, tasks);
      final back = await TaskStore.load(prefs);
      expect(back.map((t) => t.title), ['One', 'Two']);
      expect(back[1].reminderDocId, 'doc2');
    });
  });
}
