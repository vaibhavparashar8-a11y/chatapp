import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/screens/todo_screen.dart';
import 'package:chatapp/services/notification_service.dart';
import 'package:chatapp/services/reminder_service.dart';
import 'package:chatapp/services/remote_config_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationService.testMode = true;
    RemoteConfigService.testMode = true;
    ReminderService.testMode = true;
  });

  tearDown(() {
    NotificationService.testMode = false;
    RemoteConfigService.testMode = false;
    ReminderService.testMode = false;
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

  // ── Remind-other button (add_alert icon) ─────────────────────────────────────

  testWidgets('each task shows an add_alert icon for sending reminder to other',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Call dentist');
    expect(find.byIcon(Icons.add_alert_rounded), findsOneWidget);
  });

  testWidgets('two tasks show two add_alert buttons', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Task one');
    await addTask(tester, 'Task two');
    expect(find.byIcon(Icons.add_alert_rounded), findsNWidgets(2));
  });

  testWidgets('tapping add_alert opens date picker then Remind dialog',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Buy flowers');

    await tester.tap(find.byIcon(Icons.add_alert_rounded));
    await tester.pumpAndSettle();

    // Date picker is open — confirm it
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Time picker is open — confirm it
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Remind dialog is now visible
    expect(find.text('Remind Them'), findsOneWidget);
    expect(find.text('Also add to their task list'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Remind dialog checkbox is unchecked by default', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Walk dog');

    await tester.tap(find.byIcon(Icons.add_alert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox).last);
    expect(checkbox.value, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Remind dialog checkbox can be toggled', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Pick up parcel');

    await tester.tap(find.byIcon(Icons.add_alert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();

    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox).last);
    expect(checkbox.value, isTrue);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Send in Remind dialog shows snackbar confirmation',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await addTask(tester, 'Gym session');

    await tester.tap(find.byIcon(Icons.add_alert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    // ReminderService.testMode skips the Firestore write; snackbar still shows
    expect(find.text('Reminder sent to Them'), findsOneWidget);
  });
}
