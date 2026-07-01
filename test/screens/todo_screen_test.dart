import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/screens/todo_screen.dart';
import 'package:chatapp/services/notification_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Skip platform-channel calls inside NotificationService during widget tests.
    NotificationService.testMode = true;
  });

  tearDown(() {
    NotificationService.testMode = false;
  });

  Widget wrap() => const MaterialApp(home: TodoScreen());

  /// Enters [text], triggers submit, taps "Skip" on the reminder dialog, then
  /// pumps until settled. Use this helper for every test that adds a task.
  Future<void> addTask(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(); // dialog appears
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle(); // task added
  }

  // ── Empty state ─────────────────────────────────────────────────────────────

  testWidgets('shows empty-state hint when no tasks exist', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('No tasks yet.\nTap + to add one.'), findsOneWidget);
  });

  // ── Adding tasks ────────────────────────────────────────────────────────────

  testWidgets('typing a task and pressing done adds it to the list', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Buy groceries');

    expect(find.text('Buy groceries'), findsOneWidget);
    expect(find.text('No tasks yet.\nTap + to add one.'), findsNothing);
  });

  testWidgets('tapping the + FAB shows reminder dialog then adds task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Walk the dog');
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
    expect(find.text('No tasks yet.\nTap + to add one.'), findsOneWidget);
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

  // ── Completing tasks ────────────────────────────────────────────────────────

  testWidgets('checking a task moves it into the Completed section', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Finish report');

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.text('Completed (1)'), findsOneWidget);
  });

  testWidgets('unchecking a completed task moves it back to pending', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Read book');

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('Completed (1)'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('Completed (1)'), findsNothing);
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

  // ── Deleting tasks ──────────────────────────────────────────────────────────

  testWidgets('tapping the delete icon removes the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Delete me');

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

    expect(find.text('Delete me'), findsNothing);
  });

  testWidgets('swiping left dismisses the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Swipe away');

    await tester.drag(find.text('Swipe away'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('Swipe away'), findsNothing);
  });

  // ── Calendar reminder button ────────────────────────────────────────────────

  testWidgets('each task tile shows a calendar icon button', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Remind me');

    // Outlined icon = no reminder set (user tapped Skip during creation)
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
  });

  testWidgets('two tasks show two calendar buttons', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'Alpha');
    await addTask(tester, 'Beta');

    expect(find.byIcon(Icons.calendar_today_outlined), findsNWidgets(2));
  });

  // ── Reminder dialog ─────────────────────────────────────────────────────────

  testWidgets('reminder dialog appears with task title in content', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Set a reminder?'), findsOneWidget);
    expect(find.textContaining('Add a reminder for'), findsOneWidget);

    // Clean up: dismiss dialog
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
  });

  testWidgets('tapping Skip on reminder dialog adds task without dueDate', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await addTask(tester, 'No reminder task');

    expect(find.text('No reminder task'), findsOneWidget);
    // Calendar icon should still be outlined (no dueDate set)
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
  });
}
