import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/models/recurrence.dart';
import 'package:chatapp/services/notification_service.dart';
import 'package:chatapp/services/reminder_service.dart';
import 'package:chatapp/services/task_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const todosKey = 'todos_v1';

  setUp(() {
    NotificationService.testMode = true;
    ReminderService.testMode = true;
    NotificationService.debugScheduled.clear();
    NotificationService.debugCancelled.clear();
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
    List<Map<String, dynamic>>? subtasks,
  }) =>
      {
        'id': id,
        'title': title,
        'done': done,
        if (sharedId != null) 'sharedId': sharedId,
        if (reminderDocId != null) 'reminderDocId': reminderDocId,
        if (dueDate != null) 'dueDate': dueDate,
        'subtasks': subtasks ?? <dynamic>[],
      };

  Future<SharedPreferences> prefsWith(List<Map<String, dynamic>> tasks) async {
    SharedPreferences.setMockInitialValues({todosKey: jsonEncode(tasks)});
    return SharedPreferences.getInstance();
  }

  List<dynamic> storedTasks(SharedPreferences prefs) =>
      jsonDecode(prefs.getString(TaskStore.key)!) as List;

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
      expect(stored[0]['start'], newDue.toIso8601String());
      expect(stored[1]['start'], isNull,
          reason: 'creator opted out of Remind me — no due date is forced on');
    });

    test('backfills sharedId on legacy reminder_ entries', () async {
      // Pre-sync entries created on the recipient side carry the doc id inside
      // their local id. Task.fromJson now backfills the link when the list is
      // read, so it is already persisted by the time the mirror runs — the
      // mirror itself reports no change, but the task IS linked (and so is
      // reachable by later edits/deletes), which is what matters.
      final prefs = await prefsWith([
        localTask('reminder_legacy123', dueDate: due.toIso8601String()),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'legacy123', title: 'Task', scheduledAt: due)],
        applyDeletes: true,
      );
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

  group('applySharedSnapshot — subtasks', () {
    test('applies a remote subtask list onto the linked local task', () async {
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1'),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(id: 'doc1', title: 'Task', scheduledAt: due, subtasks: [
            {'id': 's1', 'title': 'Step one', 'done': false},
            {'id': 's2', 'title': 'Step two', 'done': true},
          ]),
        ],
        applyDeletes: true,
      );
      expect(changed, isTrue);
      final subs = storedTasks(prefs).first['subtasks'] as List;
      expect(subs, hasLength(2));
      expect(subs[0]['title'], 'Step one');
      expect(subs[1]['done'], isTrue);
    });

    test('a done-toggle on a remote subtask reaches the local copy', () async {
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1', subtasks: [
          {'id': 's1', 'title': 'Step', 'done': false},
        ]),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(id: 'doc1', title: 'Task', scheduledAt: due, subtasks: [
            {'id': 's1', 'title': 'Step', 'done': true},
          ]),
        ],
        applyDeletes: true,
      );
      final subs = storedTasks(prefs).first['subtasks'] as List;
      expect(subs.single['done'], isTrue);
    });

    test('a null subtasks list (legacy doc) leaves the local copy untouched',
        () async {
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1', subtasks: [
          {'id': 's1', 'title': 'Keep me', 'done': false},
        ]),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'doc1', title: 'Task', scheduledAt: due)],
        applyDeletes: true,
      );
      expect(changed, isFalse);
      final subs = storedTasks(prefs).first['subtasks'] as List;
      expect(subs.single['title'], 'Keep me');
    });

    test('an identical subtask list is not rewritten (no sync loop)', () async {
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1', subtasks: [
          {'id': 's1', 'title': 'Step', 'done': false},
        ]),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(id: 'doc1', title: 'Task', scheduledAt: due, subtasks: [
            {'id': 's1', 'title': 'Step', 'done': false},
          ]),
        ],
        applyDeletes: true,
      );
      expect(changed, isFalse);
    });
  });

  group('deliveryMapFromDocs', () {
    ({String id, String? createdBy, String? forUser, bool locallyScheduled}) doc(
      String id, {
      String? createdBy,
      String? forUser,
      bool scheduled = false,
    }) =>
        (
          id: id,
          createdBy: createdBy,
          forUser: forUser,
          locallyScheduled: scheduled
        );

    test('keeps only reminders this device sent to the other person', () {
      final map = ReminderService.deliveryMapFromDocs([
        doc('sent1', createdBy: 'A', forUser: 'B', scheduled: false),
        doc('sent2', createdBy: 'A', forUser: 'B', scheduled: true),
        doc('self', createdBy: 'A', forUser: 'A'), // my own self reminder
        doc('incoming', createdBy: 'B', forUser: 'A'), // peer → me
        doc('peerSelf', createdBy: 'B', forUser: 'B'), // peer's self reminder
      ], 'A');

      expect(map.keys.toSet(), {'sent1', 'sent2'});
      expect(map['sent1'], isFalse, reason: 'not armed on their phone yet');
      expect(map['sent2'], isTrue, reason: 'delivered & armed');
    });

    test('empty when nothing was sent to the other person', () {
      final map = ReminderService.deliveryMapFromDocs([
        doc('self', createdBy: 'A', forUser: 'A'),
        doc('incoming', createdBy: 'B', forUser: 'A'),
      ], 'A');
      expect(map, isEmpty);
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

    test('carries the creator\'s repeat onto the received task', () async {
      // Regression: recurrence was never transported, so a shared "every
      // weekday" reminder landed on the other phone as a one-shot.
      final prefs = await prefsWith([]);
      await ReminderService.insertTodoToPrefs(
        prefs,
        PendingReminder(
          id: 'doc9',
          title: 'Standup',
          scheduledAt: due,
          addToList: true,
          recurrence: Recurrence.weekdays,
        ),
      );
      expect(storedTasks(prefs).first['recurrence'], 'weekdays');
    });

    test('a one-shot reminder stores no recurrence field', () async {
      final prefs = await prefsWith([]);
      await ReminderService.insertTodoToPrefs(
        prefs,
        PendingReminder(
            id: 'doc9', title: 'Once', scheduledAt: due, addToList: true),
      );
      expect(storedTasks(prefs).first.containsKey('recurrence'), isFalse);
    });
  });

  group('applySharedSnapshot — recurrence', () {
    test('a repeat change alone re-arms the local reminder with it', () async {
      // The due date is unchanged — only the repeat differs. This used to be
      // invisible to the mirror, leaving the local copy a one-shot.
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1', dueDate: due.toIso8601String()),
      ]);
      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(
              id: 'doc1',
              title: 'Task',
              scheduledAt: due,
              recurrence: Recurrence.daily),
        ],
        applyDeletes: true,
      );
      expect(changed, isTrue);
      expect(storedTasks(prefs).first['recurrence'], 'daily');
      expect(NotificationService.debugScheduled.single.recurrence,
          Recurrence.daily);
    });

    test('clearing the repeat remotely removes the local field', () async {
      // Seeded in the v1 format with the legacy enum name — the migration and
      // the mirror must both understand it.
      final prefs = await prefsWith([
        {
          ...localTask('a', sharedId: 'doc1', dueDate: due.toIso8601String()),
          'recurrence': 'daily',
        },
      ]);

      final changed = await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'doc1', title: 'Task', scheduledAt: due)],
        applyDeletes: true,
      );
      expect(changed, isTrue);
      expect(storedTasks(prefs).first.containsKey('recurrence'), isFalse);
    });

    test('a past-dated repeating reminder is still re-armed', () async {
      // Future occurrences still fire, so an elapsed occurrence must not stop
      // the mirror re-arming it — unlike a one-shot.
      final past = DateTime.now().subtract(const Duration(days: 2));
      final prefs = await prefsWith([
        localTask('a',
            sharedId: 'doc1',
            dueDate: DateTime.now().toIso8601String()),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [
          SharedTask(
              id: 'doc1',
              title: 'Task',
              scheduledAt: past,
              recurrence: Recurrence.weekly),
        ],
        applyDeletes: true,
      );
      expect(NotificationService.debugScheduled, hasLength(1));
      expect(NotificationService.debugScheduled.single.recurrence,
          Recurrence.weekly);
    });

    test('a past-dated one-shot is not re-armed', () async {
      final past = DateTime.now().subtract(const Duration(days: 2));
      final prefs = await prefsWith([
        localTask('a',
            sharedId: 'doc1', dueDate: DateTime.now().toIso8601String()),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'doc1', title: 'Task', scheduledAt: past)],
        applyDeletes: true,
      );
      expect(NotificationService.debugScheduled, isEmpty);
    });

    test('rescheduling cancels both the local group and the doc-id alarm',
        () async {
      // A shared task can be armed under the local todo-id family (incl.
      // weekday-derived ids) AND under the doc id by the delivery path.
      final newDue = DateTime(2031, 5, 5, 8, 0);
      final prefs = await prefsWith([
        localTask('a', sharedId: 'doc1', dueDate: due.toIso8601String()),
      ]);
      await ReminderService.applySharedSnapshot(
        prefs,
        [SharedTask(id: 'doc1', title: 'Task', scheduledAt: newDue)],
        applyDeletes: true,
      );
      expect(NotificationService.debugCancelled,
          contains(NotificationService.docNotifId('doc1')));
      expect(NotificationService.debugCancelled, contains('a'.hashCode),
          reason: 'base local id');
      expect(NotificationService.debugCancelled.length, greaterThan(2),
          reason: 'weekday-derived ids are group-cancelled too');
    });
  });
}
