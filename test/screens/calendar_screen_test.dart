import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart' show mySenderId;
import 'package:chatapp/screens/calendar_screen.dart';
import 'package:chatapp/services/notification_service.dart';
import 'package:chatapp/services/reminder_service.dart';
import 'package:chatapp/services/task_store.dart';
import 'package:chatapp/utils/time_utils.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationService.debugScheduled.clear();
    NotificationService.debugCancelled.clear();
    NotificationService.testMode = true;
    ReminderService.testMode = true;
    mySenderId = 'A';
  });

  tearDown(() {
    NotificationService.testMode = false;
    ReminderService.testMode = false;
  });

  Widget wrap() => const MaterialApp(home: CalendarScreen());

  /// A task on [day] at 09:00, owned by [createdBy].
  Map<String, dynamic> task(
    String id,
    String title,
    DateTime day, {
    String createdBy = 'A',
    String? recurrence,
    bool done = false,
  }) =>
      {
        'id': id,
        'title': title,
        'done': done,
        'createdBy': createdBy,
        'start': DateTime(day.year, day.month, day.day, 9).toIso8601String(),
        if (recurrence != null) 'recurrence': recurrence,
        'subtasks': <dynamic>[],
      };

  Future<void> seed(List<Map<String, dynamic>> tasks) async {
    SharedPreferences.setMockInitialValues(
        {TaskStore.key: jsonEncode(tasks)});
  }

  final today = DateTime.now();

  // ── Rendering ──────────────────────────────────────────────────────────────

  testWidgets('opens on the current month', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text(monthYearLabel(today)), findsOneWidget);
  });

  testWidgets('shows an empty message for a day with nothing on it',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Nothing on this day'), findsOneWidget);
  });

  testWidgets('lists today\'s reminder under the grid', (tester) async {
    await seed([task('t1', 'Call plumber', today)]);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Call plumber'), findsOneWidget);
    expect(find.text('Nothing on this day'), findsNothing);
  });

  testWidgets('a reminder on another day is not listed for today',
      (tester) async {
    await seed([
      task('t1', 'Later thing', today.add(const Duration(days: 3))),
    ]);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Later thing'), findsNothing);
    expect(find.text('Nothing on this day'), findsOneWidget);
  });

  testWidgets('a daily repeat shows on today even though it started earlier',
      (tester) async {
    await seed([
      task('t1', 'Take pills', today.subtract(const Duration(days: 10)),
          recurrence: 'daily'),
    ]);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.text('Take pills'), findsOneWidget);
  });

  // ── Mine / Theirs filter ───────────────────────────────────────────────────

  group('Mine/Theirs filter', () {
    testWidgets('both are shown by default', (tester) async {
      await seed([
        task('t1', 'My thing', today, createdBy: 'A'),
        task('t2', 'Their thing', today, createdBy: 'B'),
      ]);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(find.text('My thing'), findsOneWidget);
      expect(find.text('Their thing'), findsOneWidget);
    });

    testWidgets('unticking Mine hides only my reminders', (tester) async {
      await seed([
        task('t1', 'My thing', today, createdBy: 'A'),
        task('t2', 'Their thing', today, createdBy: 'B'),
      ]);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();

      expect(find.text('My thing'), findsNothing);
      expect(find.text('Their thing'), findsOneWidget);
    });

    testWidgets('unticking Theirs hides only their reminders', (tester) async {
      await seed([
        task('t1', 'My thing', today, createdBy: 'A'),
        task('t2', 'Their thing', today, createdBy: 'B'),
      ]);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Theirs'));
      await tester.pumpAndSettle();

      expect(find.text('My thing'), findsOneWidget);
      expect(find.text('Their thing'), findsNothing);
    });

    testWidgets('the last ticked box cannot be cleared', (tester) async {
      // An empty calendar with no explanation is worse than a filter that
      // refuses to fully clear.
      await seed([
        task('t1', 'My thing', today, createdBy: 'A'),
        task('t2', 'Their thing', today, createdBy: 'B'),
      ]);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Theirs'));
      await tester.pumpAndSettle();

      // Theirs was the only one left, so it stays on and Mine comes back off.
      expect(find.text('Their thing'), findsOneWidget);
    });

    testWidgets('a task with no creator counts as mine', (tester) async {
      // Tasks stored before createdBy existed must not vanish under the filter.
      await seed([
        {
          'id': 'legacy',
          'title': 'Old task',
          'done': false,
          'start': DateTime(today.year, today.month, today.day, 9)
              .toIso8601String(),
          'subtasks': <dynamic>[],
        }
      ]);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(find.text('Old task'), findsOneWidget);

      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      expect(find.text('Old task'), findsNothing);
    });
  });

  // ── Month navigation ───────────────────────────────────────────────────────

  testWidgets('the chevrons step the month and Today returns', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(find.text(monthYearLabel(today)), findsNothing);

    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text(monthYearLabel(today)), findsOneWidget);
  });

  // ── Add / edit ─────────────────────────────────────────────────────────────

  testWidgets('the FAB adds a reminder to the selected day and arms it',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('New reminder'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Buy milk'), findsOneWidget);
    expect(NotificationService.debugScheduled.map((s) => s.title),
        contains('Buy milk'));

    // Persisted to the shared store, so the todo screen sees it too.
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(TaskStore.key)!) as List;
    expect(stored.single['title'], 'Buy milk');
    expect(stored.single['createdBy'], 'A');
  });

  testWidgets('an empty title does not create a reminder', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Dialog stays open, nothing scheduled.
    expect(find.text('New reminder'), findsOneWidget);
    expect(NotificationService.debugScheduled, isEmpty);
  });

  testWidgets('tapping a reminder edits its title and re-arms it',
      (tester) async {
    await seed([task('t1', 'Old title', today)]);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    NotificationService.debugScheduled.clear();
    NotificationService.debugCancelled.clear();

    await tester.tap(find.text('Old title'));
    await tester.pumpAndSettle();
    expect(find.text('Edit reminder'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'New title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('New title'), findsOneWidget);
    expect(find.text('Old title'), findsNothing);
    // Old schedule cleared, new one armed under the same id.
    expect(NotificationService.debugCancelled, contains('t1'.hashCode));
    expect(NotificationService.debugScheduled.map((s) => s.title),
        contains('New title'));
  });

  testWidgets('checking a reminder marks it done', (tester) async {
    await seed([task('t1', 'Finish it', today)]);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(TaskStore.key)!) as List;
    expect(stored.single['done'], isTrue);
  });

  testWidgets('swiping a reminder away deletes and cancels it', (tester) async {
    await seed([task('t1', 'Remove me', today)]);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.drag(find.text('Remove me'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('Remove me'), findsNothing);
    expect(NotificationService.debugCancelled, contains('t1'.hashCode));
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(TaskStore.key)!) as List;
    expect(stored, isEmpty);
  });
}
