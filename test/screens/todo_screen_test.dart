import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/screens/todo_screen.dart';
import 'package:chatapp/services/notification_service.dart';
import 'package:chatapp/services/reminder_service.dart';
import 'package:chatapp/services/remote_config_service.dart';
import 'package:chatapp/services/device_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationService.debugScheduled.clear();
    NotificationService.testMode = true;
    RemoteConfigService.testMode = true;
    ReminderService.testMode = true;
    DeviceService.testMode = true;
  });

  tearDown(() {
    NotificationService.testMode = false;
    RemoteConfigService.testMode = false;
    ReminderService.testMode = false;
    DeviceService.testMode = false;
  });

  Widget wrap() => const MaterialApp(home: TodoScreen());

  /// Adds a task via the bottom input bar, skipping the reminder dialog.
  Future<void> addTask(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
  }

  /// Finds the AppBar search TextField by hint text.
  Finder searchField() => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Search tasks...',
      );

  // ── Empty state ──────────────────────────────────────────────────────────────

  testWidgets('shows empty-state when no tasks exist', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('No tasks yet'), findsOneWidget);
    expect(find.text('Add a task below to get started'), findsOneWidget);
  });

  // ── Adding tasks ─────────────────────────────────────────────────────────────

  testWidgets('typing a task and pressing done adds it to the list', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Buy groceries');
    expect(find.text('Buy groceries'), findsOneWidget);
    expect(find.text('No tasks yet'), findsNothing);
  });

  testWidgets('tapping the + FAB shows reminder dialog then adds task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Walk the dog');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Set a reminder?'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Walk the dog'), findsOneWidget);
  });

  testWidgets('empty input does not show dialog or add a task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    expect(find.text('Set a reminder?'), findsNothing);
    expect(find.text('No tasks yet'), findsOneWidget);
  });

  testWidgets('multiple tasks all appear in the list', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    for (final title in ['Task A', 'Task B', 'Task C']) {
      await addTask(tester, title);
    }
    expect(find.text('Task A'), findsOneWidget);
    expect(find.text('Task B'), findsOneWidget);
    expect(find.text('Task C'), findsOneWidget);
  });

  // ── Completing tasks ──────────────────────────────────────────────────────────

  testWidgets('checking a task moves it into the Completed section', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Finish report');
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('COMPLETED (1)'), findsOneWidget);
  });

  testWidgets('unchecking a completed task moves it back to pending', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Read book');
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('COMPLETED (1)'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('COMPLETED (1)'), findsNothing);
  });

  testWidgets('completed task text is rendered with strikethrough', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Done task');
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    final textWidget = tester.widget<Text>(find.text('Done task'));
    expect(textWidget.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('reminderDocId link survives a load → save round-trip',
      (tester) async {
    // A task backed by a stored-only reminder doc (self / remind-them) must
    // keep its reminderDocId across persistence so deletion can later remove
    // the Firestore doc.
    SharedPreferences.setMockInitialValues({
      'todos_v1': jsonEncode([
        {
          'id': 't1',
          'title': 'Backup task',
          'done': false,
          'reminderDocId': 'backup-doc-1',
          'dueDate': DateTime(2030, 1, 1, 9, 0).toIso8601String(),
          'subtasks': <dynamic>[],
        }
      ]),
    });
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Backup task'), findsOneWidget);

    // Toggling done triggers _saveTodos() — re-serialising the task.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('todos_v1')!) as List;
    expect(stored.first['reminderDocId'], 'backup-doc-1');
    expect(stored.first['done'], isTrue);
  });

  testWidgets('restores todos from the Firestore backup on a fresh install',
      (tester) async {
    // Fresh install: no local todos, but a role-keyed backup exists in Firestore.
    ReminderService.debugTodoBackup = jsonEncode([
      {'id': 't1', 'title': 'Restored reminder', 'done': false, 'subtasks': []},
    ]);
    addTearDown(() => ReminderService.debugTodoBackup = null);
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // The backed-up task appears and is persisted locally so it won't refetch.
    expect(find.text('Restored reminder'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('todos_v1'), isNotNull);
  });

  testWidgets('records todoLastOpened when the todo app opens', (tester) async {
    DeviceService.debugTodoOpenedWrites = 0;
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(DeviceService.debugTodoOpenedWrites, greaterThan(0));
  });

  // ── Deleting tasks ────────────────────────────────────────────────────────────

  testWidgets('swiping left dismisses the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Swipe away');
    await tester.drag(find.text('Swipe away'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Swipe away'), findsNothing);
  });

  // ── Alarm reminder button ─────────────────────────────────────────────────────

  testWidgets('each task tile shows an alarm icon button', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Remind me');
    expect(find.byIcon(Icons.add_alarm_rounded), findsOneWidget);
  });

  testWidgets('two tasks show two alarm buttons', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Alpha');
    await addTask(tester, 'Beta');
    expect(find.byIcon(Icons.add_alarm_rounded), findsNWidgets(2));
  });

  // ── Reminder dialog ───────────────────────────────────────────────────────────

  testWidgets('reminder dialog shows task title in content', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Buy milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Set a reminder?'), findsOneWidget);
    expect(find.textContaining('Add a reminder for'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
  });

  // ── Search ───────────────────────────────────────────────────────────────────

  group('search', () {
    testWidgets('search icon is visible in AppBar', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('tapping search icon activates search mode with X button', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(searchField(), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('typing filters tasks by title', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Buy groceries');
      await addTask(tester, 'Clean house');

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'groc');
      await tester.pump();

      expect(find.text('Buy groceries'), findsOneWidget);
      expect(find.text('Clean house'), findsNothing);
    });

    testWidgets('search is case-insensitive', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'BUY MILK');

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'buy milk');
      await tester.pump();

      expect(find.text('BUY MILK'), findsOneWidget);
    });

    testWidgets('no match shows No matching tasks empty state', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Buy groceries');

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'zzz');
      await tester.pump();

      expect(find.text('No matching tasks'), findsOneWidget);
      expect(find.text('Buy groceries'), findsNothing);
    });

    testWidgets('tapping X clears search and restores full list', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Task Alpha');
      await addTask(tester, 'Task Beta');

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'alpha');
      await tester.pump();
      expect(find.text('Task Beta'), findsNothing);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Task Alpha'), findsOneWidget);
      expect(find.text('Task Beta'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('completed tasks are also filtered by search', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Pending task');
      await addTask(tester, 'Done task');
      // Mark second task done
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'done');
      await tester.pump();

      expect(find.text('Done task'), findsOneWidget);
      expect(find.text('Pending task'), findsNothing);
    });

    testWidgets('searching subtask text shows parent task', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Parent task');
      await addTask(tester, 'Other task');

      // Expand parent task to reveal subtask input
      await tester.tap(find.text('Parent task'));
      await tester.pumpAndSettle();

      // Add a subtask
      final subtaskField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Add sub-task...',
      );
      await tester.enterText(subtaskField, 'unique subtask keyword');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Now search for the subtask keyword
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'unique subtask');
      await tester.pump();

      expect(find.text('Parent task'), findsOneWidget);
      expect(find.text('Other task'), findsNothing);
    });

    testWidgets('tapping the edit icon renames a sub-task', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Parent');

      // Expand and add a sub-task.
      await tester.tap(find.text('Parent'));
      await tester.pumpAndSettle();
      final subField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Add sub-task...',
      );
      await tester.enterText(subField, 'Old name');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Old name'), findsOneWidget);

      // Open the edit dialog via the pencil icon and rename it.
      await tester.tap(find.byIcon(Icons.edit_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Edit sub-task'), findsOneWidget);
      await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == 'Sub-task'),
        'New name',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('New name'), findsOneWidget);
      expect(find.text('Old name'), findsNothing);
    });

    testWidgets('empty search query shows all tasks', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();
      await addTask(tester, 'Apple');
      await addTask(tester, 'Banana');

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      // Type then clear
      await tester.enterText(searchField(), 'app');
      await tester.pump();
      expect(find.text('Banana'), findsNothing);

      await tester.enterText(searchField(), '');
      await tester.pump();
      expect(find.text('Apple'), findsOneWidget);
      expect(find.text('Banana'), findsOneWidget);
    });
  });

  // ── Edit task (long-press) ──────────────────────────────────────────────────

  testWidgets('long-press on a task opens the Edit Task dialog prefilled',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Pay rent');

    await tester.longPress(find.text('Pay rent'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Task'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
    );
    expect(field.controller!.text, 'Pay rent');
  });

  testWidgets('saving a new title renames the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Old name');

    await tester.longPress(find.text('Old name'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'New name',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('New name'), findsOneWidget);
    expect(find.text('Old name'), findsNothing);
  });

  testWidgets('cancelling the edit dialog keeps the original title',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Keep me');

    await tester.longPress(find.text('Keep me'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'Discarded',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Keep me'), findsOneWidget);
    expect(find.text('Discarded'), findsNothing);
  });

  // ── Unified Set Reminder dialog ───────────────────────────────────────────────

  testWidgets('no add_alert icon — only one alarm button per task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Call dentist');
    expect(find.byIcon(Icons.add_alert_rounded), findsNothing);
    expect(find.byIcon(Icons.add_alarm_rounded), findsOneWidget);
  });

  testWidgets('tapping alarm opens date/time pickers then Set Reminder dialog',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Buy flowers');

    await tester.tap(find.byIcon(Icons.add_alarm_rounded));
    await tester.pumpAndSettle();

    // Date picker
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Time picker
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Unified dialog is visible with both options
    expect(find.text('Set Reminder'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
    expect(find.text('Notify'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Set Reminder dialog: Remind me pre-checked, Notify unchecked',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Walk dog');

    await tester.tap(find.byIcon(Icons.add_alarm_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    // First checkbox is the task tile's done-checkbox, next two are in the dialog
    final remindMe = checkboxes[checkboxes.length - 2];
    final remindOther = checkboxes[checkboxes.length - 1];
    expect(remindMe.value, isTrue);
    expect(remindOther.value, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('checking Notify reveals Add to notify task list option',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Pick up parcel');

    await tester.tap(find.byIcon(Icons.add_alarm_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    expect(find.text('Add to notify task list'), findsNothing);

    // Tap the "Notify" checkbox (last checkbox in dialog)
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();

    expect(find.text('Add to notify task list'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Set with Remind me only shows reminder-set snackbar',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Morning run');

    await tester.tap(find.byIcon(Icons.add_alarm_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    // Remind me is already checked; leave Notify unchecked
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    // NotificationService.testMode returns true — snackbar shows formatted date
    expect(find.textContaining('Reminder set for'), findsOneWidget);
    expect(find.text('Notified'), findsNothing);
  });

  testWidgets('Set with Notify checked shows Notified snackbar',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Gym session');

    await tester.tap(find.byIcon(Icons.add_alarm_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    // Checkboxes in tree: [0]=task-done, [1]=Remind me (checked), [2]=Notify
    // Uncheck "Remind me" so only the "send to other" path runs.
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    // Check "Notify" (still index 2 / last since no extra checkbox yet)
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();

    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    // ReminderService.testMode skips Firestore; snackbar still shows
    expect(find.text('Notified'), findsOneWidget);
  });

  // ── Re-arm on launch (survives APK update) ───────────────────────────────────

  testWidgets('re-arms pending reminders on launch, skipping elapsed/done',
      (tester) async {
    final future = DateTime.now().add(const Duration(days: 1));
    final past = DateTime.now().subtract(const Duration(days: 1));
    SharedPreferences.setMockInitialValues({
      'todos_v1': jsonEncode([
        {'id': 'a', 'title': 'Future one-shot', 'done': false,
          'dueDate': future.toIso8601String(), 'subtasks': []},
        {'id': 'b', 'title': 'Past one-shot', 'done': false,
          'dueDate': past.toIso8601String(), 'subtasks': []},
        {'id': 'c', 'title': 'Daily recurring', 'done': false,
          'dueDate': past.toIso8601String(), 'recurrence': 'daily',
          'subtasks': []},
        {'id': 'd', 'title': 'Done task', 'done': true,
          'dueDate': future.toIso8601String(), 'subtasks': []},
        {'id': 'e', 'title': 'No reminder', 'done': false, 'subtasks': []},
      ]),
    });
    NotificationService.debugScheduled.clear();

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final titles =
        NotificationService.debugScheduled.map((s) => s.title).toSet();
    // Future one-shot and (past-due) recurring are re-armed.
    expect(titles, containsAll(<String>{'Future one-shot', 'Daily recurring'}));
    // Elapsed one-shot, done task, and reminder-less task are left alone.
    expect(titles, isNot(contains('Past one-shot')));
    expect(titles, isNot(contains('Done task')));
    expect(titles, isNot(contains('No reminder')));
  });

  // ── Delivery confirmation ────────────────────────────────────────────────────

  testWidgets('shows Sent then Delivered for a reminder sent to the other phone',
      (tester) async {
    final delivery = StreamController<Map<String, bool>>.broadcast();
    ReminderService.debugDeliveryStream = delivery.stream;
    addTearDown(() {
      ReminderService.debugDeliveryStream = null;
      delivery.close();
    });
    SharedPreferences.setMockInitialValues({
      'todos_v1': jsonEncode([
        {'id': 't1', 'title': 'Call plumber', 'done': false,
          'sharedId': 'doc1', 'subtasks': []},
      ]),
    });

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // Their phone hasn't armed it yet.
    delivery.add({'doc1': false});
    await tester.pumpAndSettle();
    expect(find.text('Not delivered'), findsOneWidget);
    expect(find.text('Delivered'), findsNothing);

    // Their phone received and scheduled it.
    delivery.add({'doc1': true});
    await tester.pumpAndSettle();
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Not delivered'), findsNothing);
  });

  testWidgets('no delivery badge for a task with no outgoing reminder',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'todos_v1': jsonEncode([
        {'id': 't1', 'title': 'Personal task', 'done': false, 'subtasks': []},
      ]),
    });
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Not delivered'), findsNothing);
    expect(find.text('Delivered'), findsNothing);
  });
}
