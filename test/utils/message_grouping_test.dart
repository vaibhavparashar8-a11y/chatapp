import 'package:chatapp/models/message.dart';
import 'package:chatapp/utils/message_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Message msg({
    required String sender,
    required DateTime at,
    MessageType type = MessageType.text,
    String id = 'm',
  }) =>
      Message(id: id, sender: sender, text: 't', type: type, timestamp: at);

  final base = DateTime(2026, 8, 18, 12, 0);

  group('layoutMessages — grouping', () {
    test('consecutive messages from one sender form a single run', () {
      final layouts = layoutMessages([
        msg(sender: 'A', at: base),
        msg(sender: 'A', at: base.add(const Duration(minutes: 1))),
        msg(sender: 'A', at: base.add(const Duration(minutes: 2))),
      ]);

      expect(layouts.map((l) => l.isFirstInGroup), [true, false, false]);
      // Only the last draws the tail + timestamp.
      expect(layouts.map((l) => l.isLastInGroup), [false, false, true]);
    });

    test('a different sender starts a new run', () {
      final layouts = layoutMessages([
        msg(sender: 'A', at: base),
        msg(sender: 'B', at: base.add(const Duration(minutes: 1))),
      ]);

      expect(layouts[0].isLastInGroup, isTrue);
      expect(layouts[1].isFirstInGroup, isTrue);
    });

    test('a gap longer than the window breaks the run', () {
      final layouts = layoutMessages([
        msg(sender: 'A', at: base),
        msg(sender: 'A', at: base.add(const Duration(minutes: 6))),
      ]);

      expect(layouts[0].isLastInGroup, isTrue);
      expect(layouts[1].isFirstInGroup, isTrue);
    });

    test('exactly at the window still groups', () {
      final layouts = layoutMessages([
        msg(sender: 'A', at: base),
        msg(sender: 'A', at: base.add(const Duration(minutes: 5))),
      ]);

      expect(layouts[1].isFirstInGroup, isFalse);
    });

    // Two messages a minute apart across midnight are the same conversation but
    // must not share a run — a date chip lands between them.
    test('a run never spans midnight', () {
      final beforeMidnight = DateTime(2026, 8, 18, 23, 59);
      final layouts = layoutMessages([
        msg(sender: 'A', at: beforeMidnight),
        msg(sender: 'A', at: beforeMidnight.add(const Duration(minutes: 1))),
      ]);

      expect(layouts[0].isLastInGroup, isTrue);
      expect(layouts[1].isFirstInGroup, isTrue);
      expect(layouts[1].showDateChip, isTrue);
    });

    // Call events render as centred dividers, so grouping across one would hide
    // a real message's tail and timestamp.
    test('a call event never joins a run and does not merge the two halves', () {
      final layouts = layoutMessages([
        msg(sender: 'A', at: base),
        msg(sender: 'system', at: base.add(const Duration(minutes: 1)), type: MessageType.callEvent),
        msg(sender: 'A', at: base.add(const Duration(minutes: 2))),
      ]);

      expect(layouts[0].isLastInGroup, isTrue);
      expect(layouts[1].isFirstInGroup, isTrue);
      expect(layouts[1].isLastInGroup, isTrue);
      expect(layouts[2].isFirstInGroup, isTrue);
    });

    test('a lone message is both first and last', () {
      final layouts = layoutMessages([msg(sender: 'A', at: base)]);
      expect(layouts.single.isFirstInGroup, isTrue);
      expect(layouts.single.isLastInGroup, isTrue);
    });

    test('an empty list produces no layouts', () {
      expect(layoutMessages([]), isEmpty);
    });
  });

  group('layoutMessages — date chips', () {
    test('the first message always gets one', () {
      expect(layoutMessages([msg(sender: 'A', at: base)]).single.showDateChip,
          isTrue);
    });

    test('only the first message of each day gets one', () {
      final layouts = layoutMessages([
        msg(sender: 'A', at: DateTime(2026, 8, 17, 9, 0)),
        msg(sender: 'A', at: DateTime(2026, 8, 17, 21, 0)),
        msg(sender: 'A', at: DateTime(2026, 8, 18, 8, 0)),
      ]);

      expect(layouts.map((l) => l.showDateChip), [true, false, true]);
    });
  });

  group('formatDateSeparator', () {
    final now = DateTime(2026, 8, 18, 15, 0);

    test('names today and yesterday', () {
      expect(formatDateSeparator(DateTime(2026, 8, 18, 1), now: now), 'Today');
      expect(
          formatDateSeparator(DateTime(2026, 8, 17, 23), now: now), 'Yesterday');
    });

    test('uses the weekday within the past week', () {
      // 2026-08-14 is a Friday.
      expect(formatDateSeparator(DateTime(2026, 8, 14), now: now), 'Fri 14 Aug');
    });

    test('drops the weekday beyond a week, and adds the year beyond this one',
        () {
      expect(formatDateSeparator(DateTime(2026, 6, 2), now: now), '2 Jun');
      expect(formatDateSeparator(DateTime(2025, 12, 25), now: now), '25 Dec 2025');
    });

    // Late-night edge: 00:30 is "Today" even though it is only hours after a
    // message that is "Yesterday".
    test('compares calendar days, not elapsed hours', () {
      final justAfterMidnight = DateTime(2026, 8, 18, 0, 30);
      expect(formatDateSeparator(justAfterMidnight, now: now), 'Today');
      expect(formatDateSeparator(DateTime(2026, 8, 17, 23, 30), now: now),
          'Yesterday');
    });
  });
}
