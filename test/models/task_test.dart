import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/recurrence.dart';
import 'package:chatapp/models/task.dart';

void main() {
  group('storage round-trip', () {
    test('a full task survives toJson → fromJson', () {
      final t = Task(
        't1',
        'Dentist',
        done: true,
        start: DateTime(2030, 5, 1, 9, 0),
        subtasks: [SubTask('s1', 'Bring card', done: true)],
        createdBy: 'B',
        sharedId: 'doc1',
        recurrence: Recurrence.weekdays,
      );

      final back = Task.fromJson(t.toJson());

      expect(back.id, 't1');
      expect(back.title, 'Dentist');
      expect(back.done, isTrue);
      expect(back.start, DateTime(2030, 5, 1, 9, 0));
      expect(back.subtasks.single.title, 'Bring card');
      expect(back.subtasks.single.done, isTrue);
      expect(back.createdBy, 'B');
      expect(back.sharedId, 'doc1');
      expect(back.recurrence, Recurrence.weekdays);
    });

    test('empty optional fields are omitted from the JSON', () {
      final json = Task('t1', 'Bare').toJson();
      for (final key in [
        'start',
        'recurrence',
        'createdBy',
        'sharedId',
        'reminderDocId'
      ]) {
        expect(json.containsKey(key), isFalse, reason: key);
      }
    });
  });

  group('reads the v1 storage format', () {
    test('dueDate is read as start', () {
      final t = Task.fromJson({
        'id': 't1',
        'title': 'Old task',
        'done': false,
        'dueDate': DateTime(2030, 1, 1, 9, 0).toIso8601String(),
        'subtasks': <dynamic>[],
      });
      expect(t.start, DateTime(2030, 1, 1, 9, 0));
    });

    test('a stored recurrence name is read back', () {
      final t = Task.fromJson({
        'id': 't1',
        'title': 'Standup',
        'recurrence': 'weekdays',
        'subtasks': <dynamic>[],
      });
      expect(t.recurrence, Recurrence.weekdays);
    });

    test('an unknown recurrence falls back to none', () {
      final t = Task.fromJson({
        'id': 't1',
        'title': 'Task',
        'recurrence': 'fortnightly',
        'subtasks': <dynamic>[],
      });
      expect(t.recurrence, Recurrence.none);
    });

    test('a legacy reminder_ id backfills sharedId', () {
      // Pre-sync copies created on the recipient side carry the doc id inside
      // the local id; the link must be recovered so edits/deletes reach it.
      final t = Task.fromJson({
        'id': 'reminder_doc9',
        'title': 'From them',
        'subtasks': <dynamic>[],
      });
      expect(t.sharedId, 'doc9');
      expect(t.backingDocId, 'doc9');
    });

    test('an explicit sharedId is not overwritten by the id heuristic', () {
      final t = Task.fromJson({
        'id': 'reminder_doc9',
        'title': 'From them',
        'sharedId': 'real-doc',
        'subtasks': <dynamic>[],
      });
      expect(t.sharedId, 'real-doc');
    });
  });

  group('isMine — drives the calendar Mine/Theirs filter', () {
    test('matches on the creator role', () {
      expect(Task('t', 'x', createdBy: 'A').isMine('A'), isTrue);
      expect(Task('t', 'x', createdBy: 'A').isMine('B'), isFalse);
      expect(Task('t', 'x', createdBy: 'B').isMine('B'), isTrue);
    });

    test('a task with no creator counts as mine', () {
      // Tasks stored before createdBy existed can only have been written on
      // this phone, so they must not disappear when the filter is on.
      expect(Task('t', 'x').isMine('A'), isTrue);
      expect(Task('t', 'x').isMine('B'), isTrue);
    });
  });

  group('derived values', () {
    test('backingDocId prefers sharedId over reminderDocId', () {
      expect(
          Task('t', 'x', sharedId: 'a', reminderDocId: 'b').backingDocId, 'a');
      expect(Task('t', 'x', reminderDocId: 'b').backingDocId, 'b');
      expect(Task('t', 'x').backingDocId, isNull);
    });

    test('hasReminder and doneSubtasks', () {
      expect(Task('t', 'x').hasReminder, isFalse);
      expect(Task('t', 'x', start: DateTime(2030)).hasReminder, isTrue);
      final t = Task('t', 'x', subtasks: [
        SubTask('a', 'one', done: true),
        SubTask('b', 'two'),
      ]);
      expect(t.doneSubtasks, 1);
    });
  });
}
