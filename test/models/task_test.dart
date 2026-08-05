import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/recurrence.dart';
import 'package:chatapp/models/recurrence_rule.dart';
import 'package:chatapp/models/task.dart';

void main() {
  group('storage round-trip', () {
    test('a full task survives toJson → fromJson', () {
      final t = Task(
        't1',
        'Dentist',
        done: true,
        start: DateTime(2030, 5, 1, 9, 0),
        end: DateTime(2030, 5, 1, 10, 30),
        allDay: false,
        alerts: const [Duration(minutes: 10), Duration(hours: 1)],
        subtasks: [SubTask('s1', 'Bring card', done: true)],
        sharedId: 'doc1',
        recurrence: RecurrenceRule(freq: Freq.weekly, interval: 2),
      );

      final back = Task.fromJson(t.toJson());

      expect(back.id, 't1');
      expect(back.title, 'Dentist');
      expect(back.done, isTrue);
      expect(back.start, DateTime(2030, 5, 1, 9, 0));
      expect(back.end, DateTime(2030, 5, 1, 10, 30));
      expect(back.allDay, isFalse);
      expect(back.alerts, const [Duration(minutes: 10), Duration(hours: 1)]);
      expect(back.subtasks.single.title, 'Bring card');
      expect(back.subtasks.single.done, isTrue);
      expect(back.sharedId, 'doc1');
      expect(back.recurrence, RecurrenceRule(freq: Freq.weekly, interval: 2));
    });

    test('an all-day task keeps its flag', () {
      final t = Task('t1', 'Holiday',
          start: DateTime(2030, 5, 1), allDay: true);
      expect(Task.fromJson(t.toJson()).allDay, isTrue);
    });

    test('empty optional fields are omitted from the JSON', () {
      final json = Task('t1', 'Bare').toJson();
      for (final key in ['start', 'end', 'allDay', 'alerts', 'rrule',
        'sharedId', 'reminderDocId']) {
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
      expect(t.end, isNull);
      expect(t.allDay, isFalse);
      expect(t.alerts, isEmpty);
    });

    test('a legacy recurrence enum name is read as a rule', () {
      final t = Task.fromJson({
        'id': 't1',
        'title': 'Standup',
        'recurrence': 'weekdays',
        'subtasks': <dynamic>[],
      });
      expect(t.recurrence, RecurrenceRule.fromLegacy(Recurrence.weekdays));
    });

    test('rrule wins over a stale legacy recurrence field', () {
      final t = Task.fromJson({
        'id': 't1',
        'title': 'Task',
        'rrule': 'FREQ=DAILY;INTERVAL=3',
        'recurrence': 'none',
        'subtasks': <dynamic>[],
      });
      expect(t.recurrence, RecurrenceRule(freq: Freq.daily, interval: 3));
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

  group('derived values', () {
    test('backingDocId prefers sharedId over reminderDocId', () {
      expect(
          Task('t', 'x', sharedId: 'a', reminderDocId: 'b').backingDocId, 'a');
      expect(Task('t', 'x', reminderDocId: 'b').backingDocId, 'b');
      expect(Task('t', 'x').backingDocId, isNull);
    });

    test('duration is null unless both ends are set', () {
      final start = DateTime(2030, 1, 1, 9);
      expect(Task('t', 'x', start: start).duration, isNull);
      expect(Task('t', 'x', end: start).duration, isNull);
      expect(
          Task('t', 'x', start: start, end: start.add(const Duration(hours: 2)))
              .duration,
          const Duration(hours: 2));
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
