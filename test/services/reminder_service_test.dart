import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/services/notification_service.dart';
import 'package:chatapp/services/reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const todosKey = 'todos_v1';

  setUp(() {
    NotificationService.testMode = true;
    ReminderService.testMode = true;
  });

  tearDown(() {
    NotificationService.testMode = false;
    ReminderService.testMode = false;
  });

  Map<String, dynamic> localTask(
    String id, {
    String title = 'Task',
    bool done = false,
    String? sharedId,
    String? reminderDocId,
    String? dueDate,
  }) =>
      {
        'id': id,
        'title': title,
        'done': done,
        if (sharedId != null) 'sharedId': sharedId,
        if (reminderDocId != null) 'reminderDocId': reminderDocId,
        if (dueDate != null) 'dueDate': dueDate,
        'subtasks': <dynamic>[],
      };

  Future<SharedPreferences> prefsWith(List<Map<String, dynamic>> tasks) async {
    SharedPreferences.setMockInitialValues({todosKey: jsonEncode(tasks)});
    return SharedPreferences.getInstance();
  }

  List<dynamic> storedTasks(SharedPreferences prefs) =>
      jsonDecode(prefs.getString(todosKey)!) as List;

  final due = DateTime(2030, 1, 1, 10, 0);

  group('applySharedSnapshot', () {
    test('applies a remote title change to the linked local task', () async {
      final prefs = await prefsWith([
        localTask('local1', title: 'Old title', sharedId: 'doc1'),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'doc1', title: 'New title', scheduledAt: due)],
        applyDeletes: true,
      );
      expect(changed, isTrue);
      expect(storedTasks(prefs).first['title'], 'New title');
    });

    test('applies remote done state only when the doc carries one', () async {
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1', done: false),
        localTask('b', sharedId: 'doc2', done: true),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(id: 'doc1', title: 'Task', scheduledAt: due, done: true),
          // doc2 has no done field (legacy doc) — must not revert local done.
          SharedTask(id: 'doc2', title: 'Task', scheduledAt: due),
        ],
        applyDeletes: true,
      );
      final stored = storedTasks(prefs);
      expect(stored[0]['done'], isTrue);
      expect(stored[1]['done'], isTrue);
    });

    test('removes the local copy when the shared doc is gone', () async {
      final prefs = await prefsWith([
        localTask('keep-me'),
        localTask('shared', sharedId: 'deleted-doc'),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [],
        applyDeletes: true,
      );
      expect(changed, isTrue);
      final stored = storedTasks(prefs);
      expect(stored, hasLength(1));
      expect(stored.first['id'], 'keep-me');
    });

    test('keeps local copies when deletes are not trusted (cache snapshot)',
        () async {
      final prefs = await prefsWith([
        localTask('shared', sharedId: 'doc1'),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [],
        applyDeletes: false,
      );
      expect(changed, isFalse);
      expect(storedTasks(prefs), hasLength(1));
    });

    test('syncs due date only onto tasks that already track one', () async {
      final withDue = due.toIso8601String();
      final newDue = DateTime(2030, 2, 2, 12, 0);
      final prefs = await prefsWith([
        localTask('has-due', sharedId: 'doc1', dueDate: withDue),
        localTask('no-due', sharedId: 'doc2'),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(id: 'doc1', title: 'Task', scheduledAt: newDue),
          SharedTask(id: 'doc2', title: 'Task', scheduledAt: newDue),
        ],
        applyDeletes: true,
      );
      final stored = storedTasks(prefs);
      expect(stored[0]['dueDate'], newDue.toIso8601String());
      expect(stored[1]['dueDate'], isNull,
          reason: 'creator opted out of Remind me — no due date is forced on');
    });

    test('backfills sharedId on legacy reminder_ entries', () async {
      final prefs = await prefsWith([
        localTask('reminder_legacy123', dueDate: due.toIso8601String()),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'legacy123', title: 'Task', scheduledAt: due)],
        applyDeletes: true,
      );
      expect(changed, isTrue);
      expect(storedTasks(prefs).first['sharedId'], 'legacy123');
    });

    test('never deletes a reminderDocId-only task (self / stored-only reminder)',
        () async {
      // Self "Remind me" reminders and remind-them-without-list reminders are
      // stored in Firestore but NOT mirrored (addToList=false), so their docs
      // never appear in sharedTasksStream. The mirror must key off sharedId
      // only and leave these tasks alone — otherwise the setter's own reminder
      // would vanish on the next server snapshot.
      final prefs = await prefsWith([
        localTask('self', reminderDocId: 'backup-doc', dueDate: due.toIso8601String()),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [],
        applyDeletes: true,
      );
      expect(changed, isFalse);
      final stored = storedTasks(prefs);
      expect(stored, hasLength(1));
      expect(stored.first['id'], 'self');
      expect(stored.first['reminderDocId'], 'backup-doc');
    });

    test('leaves purely local tasks untouched and reports no change',
        () async {
      final prefs = await prefsWith([
        localTask('mine', title: 'Private task'),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'unrelated', title: 'Other', scheduledAt: due)],
        applyDeletes: true,
      );
      expect(changed, isFalse);
      expect(storedTasks(prefs).first['title'], 'Private task');
    });

    test('no-ops when local state already matches the docs', () async {
      final prefs = await prefsWith([
        localTask('a',
            title: 'Same',
            sharedId: 'doc1',
            done: false,
            dueDate: due.toIso8601String()),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'doc1', title: 'Same', scheduledAt: due, done: false)],
        applyDeletes: true,
      );
      expect(changed, isFalse);
    });
  });

  group('insertTodoToPrefs', () {
    test('stores the sharedId link on inserted tasks', () async {
      final prefs = await prefsWith([]);
      await ReminderService.insertTodoToPrefs(
        prefs,
        PendingReminder(
            id: 'doc9', title: 'From A', scheduledAt: due, addToList: true),
      );
      final stored = storedTasks(prefs);
      expect(stored.first['id'], 'reminder_doc9');
      expect(stored.first['sharedId'], 'doc9');
    });
  });
}
