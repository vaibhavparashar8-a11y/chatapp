import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/screens/todo_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap() => const MaterialApp(home: TodoScreen());

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

    await tester.enterText(find.byType(TextField), 'Buy groceries');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('Buy groceries'), findsOneWidget);
    expect(find.text('No tasks yet.\nTap + to add one.'), findsNothing);
  });

  testWidgets('tapping the + FAB adds the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Walk the dog');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    expect(find.text('Walk the dog'), findsOneWidget);
  });

  testWidgets('empty input does not add a task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    expect(find.text('No tasks yet.\nTap + to add one.'), findsOneWidget);
  });

  testWidgets('multiple tasks all appear in the list', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    for (final title in ['Task A', 'Task B', 'Task C']) {
      await tester.enterText(find.byType(TextField), title);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    expect(find.text('Task A'), findsOneWidget);
    expect(find.text('Task B'), findsOneWidget);
    expect(find.text('Task C'), findsOneWidget);
  });

  // ── Completing tasks ────────────────────────────────────────────────────────

  testWidgets('checking a task moves it into the Completed section', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Finish report');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.text('Completed (1)'), findsOneWidget);
  });

  testWidgets('unchecking a completed task moves it back to pending', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Read book');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

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

    await tester.enterText(find.byType(TextField), 'Done task');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    final textWidget = tester.widget<Text>(find.text('Done task'));
    expect(textWidget.style?.decoration, TextDecoration.lineThrough);
  });

  // ── Deleting tasks ──────────────────────────────────────────────────────────

  testWidgets('tapping the delete icon removes the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Delete me');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // The delete icon button is the second icon in the tile's secondary row
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

    expect(find.text('Delete me'), findsNothing);
  });

  testWidgets('swiping left dismisses the task', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Swipe away');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await tester.drag(find.text('Swipe away'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('Swipe away'), findsNothing);
  });

  // ── Calendar reminder button ────────────────────────────────────────────────

  testWidgets('each task tile shows a calendar icon button', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Remind me');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Outlined icon = no reminder set yet
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
  });

  testWidgets('two tasks show two calendar buttons', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    for (final t in ['Alpha', 'Beta']) {
      await tester.enterText(find.byType(TextField), t);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    expect(find.byIcon(Icons.calendar_today_outlined), findsNWidgets(2));
  });
}
