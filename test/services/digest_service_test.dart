import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/services/digest_service.dart';

void main() {
  final day = DateTime(2026, 7, 15);

  String todosJson(List<Map<String, dynamic>> tasks) => jsonEncode(tasks);

  Map<String, dynamic> task(String title,
          {bool done = false, DateTime? due}) =>
      {
        'id': title,
        'title': title,
        'done': done,
        if (due != null) 'dueDate': due.toIso8601String(),
        'subtasks': <dynamic>[],
      };

  group('DigestService.titlesFor', () {
    test('includes only not-done tasks due on the given day', () {
      final json = todosJson([
        task('Due today', due: DateTime(2026, 7, 15, 9)),
        task('Due today but done', done: true, due: DateTime(2026, 7, 15, 10)),
        task('Due tomorrow', due: DateTime(2026, 7, 16, 9)),
        task('No due date'),
      ]);
      expect(DigestService.titlesFor(json, day), ['Due today']);
    });

    test('matches by calendar day regardless of time', () {
      final json = todosJson([
        task('Early', due: DateTime(2026, 7, 15, 0, 1)),
        task('Late', due: DateTime(2026, 7, 15, 23, 59)),
      ]);
      expect(DigestService.titlesFor(json, day), ['Early', 'Late']);
    });

    test('blank title falls back to "Task"', () {
      final json = todosJson([task('', due: DateTime(2026, 7, 15, 8))]);
      expect(DigestService.titlesFor(json, day), ['Task']);
    });

    test('null or malformed json yields empty list', () {
      expect(DigestService.titlesFor(null, day), isEmpty);
      expect(DigestService.titlesFor('not json', day), isEmpty);
    });
  });

  group('DigestService.buildBody', () {
    test('formats a unicode checklist for the day', () {
      final json = todosJson([
        task('Groceries', due: DateTime(2026, 7, 15, 9)),
        task('Dentist', due: DateTime(2026, 7, 15, 14)),
      ]);
      expect(DigestService.buildBody(json, day), '☐ Groceries\n☐ Dentist');
    });

    test('friendly message when nothing is due', () {
      final json = todosJson([task('Tomorrow', due: DateTime(2026, 7, 16))]);
      expect(DigestService.buildBody(json, day), 'No tasks scheduled today. 🎉');
    });
  });

  group('DigestPrefs', () {
    test('defaults are off at 6:30', () {
      final p = DigestPrefs.defaults();
      expect(p.enabled, false);
      expect(p.hour, 6);
      expect(p.minute, 30);
    });
  });
}
