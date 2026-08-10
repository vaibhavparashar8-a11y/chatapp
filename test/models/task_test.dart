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

    test('remindsMe survives the round-trip and defaults to true', () {
      // A reminder set only to notify the other person keeps its time but is
      // not armed on this phone — the flag is what tells the two apart.
      final t = Task('t1', 'Their errand',
          start: DateTime(2030, 5, 1, 9), remindsMe: false);
      expect(Task.fromJson(t.toJson()).remindsMe, isFalse);
      // Tasks stored before the field existed were always armed here.
      expect(
          Task.fromJson({'id': 't2', 'title': 'Old', 'subtasks': []}).remindsMe,
          isTrue);
    });

    test('empty optional fields are omitted from the JSON', () {
      final json = Task('t1', 'Bare').toJson();
      for (final key in [
        'start',
        'recurrence',
        'createdBy',
        'sharedId',
        'reminderDocId',
        'remindsMe'
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

  group('occursOn — which calendar days a reminder is drawn on', () {
    // Mon 2026-08-03 .. Sun 2026-08-09.
    final mon = DateTime(2026, 8, 3);
    final wed = DateTime(2026, 8, 5);
    final sat = DateTime(2026, 8, 8);
    final sun = DateTime(2026, 8, 9);
    final nextMon = DateTime(2026, 8, 10);

    Task at(DateTime start, Recurrence r) =>
        Task('t', 'x', start: start, recurrence: r);

    test('a task with no reminder occurs nowhere', () {
      expect(Task('t', 'x').occursOn(mon), isFalse);
    });

    test('a one-shot occurs only on its own date', () {
      final t = at(DateTime(2026, 8, 5, 9, 30), Recurrence.none);
      expect(t.occursOn(wed), isTrue);
      expect(t.occursOn(mon), isFalse);
      expect(t.occursOn(nextMon), isFalse);
    });

    test('the time of day does not affect which day it lands on', () {
      final late = at(DateTime(2026, 8, 5, 23, 59), Recurrence.none);
      final early = at(DateTime(2026, 8, 5, 0, 1), Recurrence.none);
      expect(late.occursOn(wed), isTrue);
      expect(early.occursOn(wed), isTrue);
    });

    test('nothing occurs before the day it was set', () {
      final t = at(DateTime(2026, 8, 5, 9), Recurrence.daily);
      expect(t.occursOn(mon), isFalse, reason: 'two days before it existed');
      expect(t.occursOn(wed), isTrue);
    });

    test('daily occurs every day from the start onward', () {
      final t = at(DateTime(2026, 8, 3, 9), Recurrence.daily);
      for (final d in [mon, wed, sat, sun, nextMon]) {
        expect(t.occursOn(d), isTrue, reason: '$d');
      }
    });

    test('weekly occurs on the start weekday only', () {
      final t = at(DateTime(2026, 8, 3, 9), Recurrence.weekly); // a Monday
      expect(t.occursOn(mon), isTrue);
      expect(t.occursOn(nextMon), isTrue);
      expect(t.occursOn(wed), isFalse);
    });

    test('weekdays covers Mon–Fri, weekends covers Sat–Sun', () {
      final wk = at(DateTime(2026, 8, 3, 9), Recurrence.weekdays);
      expect(wk.occursOn(mon), isTrue);
      expect(wk.occursOn(wed), isTrue);
      expect(wk.occursOn(sat), isFalse);
      expect(wk.occursOn(sun), isFalse);

      final we = at(DateTime(2026, 8, 3, 9), Recurrence.weekends);
      expect(we.occursOn(sat), isTrue);
      expect(we.occursOn(sun), isTrue);
      expect(we.occursOn(mon), isFalse);
    });
  });

  group('occurrenceOn', () {
    test('places the start time on the requested day', () {
      final t = Task('t', 'x',
          start: DateTime(2026, 8, 3, 7, 45), recurrence: Recurrence.daily);
      expect(t.occurrenceOn(DateTime(2026, 8, 20)),
          DateTime(2026, 8, 20, 7, 45));
    });

    test('is null on a day the task does not occur', () {
      final t = Task('t', 'x', start: DateTime(2026, 8, 3, 7, 45));
      expect(t.occurrenceOn(DateTime(2026, 8, 4)), isNull);
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
