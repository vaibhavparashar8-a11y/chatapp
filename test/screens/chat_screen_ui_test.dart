import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/screens/chat_screen.dart';
import 'package:chatapp/services/device_service.dart';
import 'package:chatapp/services/log_service.dart';
import 'package:chatapp/widgets/message_bubble.dart';
import '../helpers/fake_chat_repository.dart';

/// Presentation of the message list: date separators and grouped bubble runs.
void main() {
  late FakeChatRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceService.testMode = true;
    LogService.testMode = true;
    mySenderId = 'A';
    repo = FakeChatRepository();
  });

  tearDown(() {
    DeviceService.testMode = false;
    LogService.testMode = false;
    repo.close();
  });

  Message msg(String sender, DateTime at, {String? id, String text = 'hello'}) =>
      Message(
        id: id ?? '${sender}_${at.millisecondsSinceEpoch}',
        sender: sender,
        text: text,
        type: MessageType.text,
        timestamp: at,
      );

  Future<void> pumpWith(WidgetTester tester, List<Message> messages) async {
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        repository: repo,
        callSignalProvider: () => const Stream.empty(),
      ),
    ));
    await tester.pump();
    repo.emitMessages(messages);
    await tester.pump();
    await tester.pump();
  }

  group('date separators', () {
    testWidgets('today\'s messages sit under a "Today" chip', (tester) async {
      final now = DateTime.now();
      await pumpWith(tester, [msg('B', now.subtract(const Duration(hours: 1)))]);

      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('a chip appears per day, not per message', (tester) async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      await pumpWith(tester, [
        msg('B', DateTime(yesterday.year, yesterday.month, yesterday.day, 9)),
        msg('B', DateTime(yesterday.year, yesterday.month, yesterday.day, 21)),
        msg('B', DateTime(now.year, now.month, now.day, 8)),
      ]);

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
    });
  });

  group('grouped bubble runs', () {
    testWidgets('a burst from one sender shows a single timestamp',
        (tester) async {
      final at = DateTime.now().subtract(const Duration(hours: 2));
      await pumpWith(tester, [
        msg('B', at, id: 'm1', text: 'one'),
        msg('B', at.add(const Duration(minutes: 1)), id: 'm2', text: 'two'),
        msg('B', at.add(const Duration(minutes: 2)), id: 'm3', text: 'three'),
      ]);

      // All three are visible…
      expect(find.text('one'), findsOneWidget);
      expect(find.text('three'), findsOneWidget);
      // …but only the last of the run carries the clock.
      final bubbles = tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .toList();
      expect(bubbles.where((b) => b.isLastInGroup), hasLength(1));
      expect(bubbles.where((b) => b.isFirstInGroup), hasLength(1));
    });

    testWidgets('alternating senders each keep their own tail',
        (tester) async {
      final at = DateTime.now().subtract(const Duration(hours: 2));
      await pumpWith(tester, [
        msg('B', at, id: 'm1'),
        msg('A', at.add(const Duration(minutes: 1)), id: 'm2'),
      ]);

      final bubbles =
          tester.widgetList<MessageBubble>(find.byType(MessageBubble));
      expect(bubbles.every((b) => b.isFirstInGroup && b.isLastInGroup), isTrue);
    });

    testWidgets('messages far apart in time are not grouped', (tester) async {
      final at = DateTime.now().subtract(const Duration(hours: 5));
      await pumpWith(tester, [
        msg('B', at, id: 'm1'),
        msg('B', at.add(const Duration(hours: 1)), id: 'm2'),
      ]);

      final bubbles =
          tester.widgetList<MessageBubble>(find.byType(MessageBubble));
      expect(bubbles.every((b) => b.isLastInGroup), isTrue);
    });
  });

  group('empty state', () {
    testWidgets('shows the private-chat message with no date chip',
        (tester) async {
      await pumpWith(tester, []);

      expect(find.text('Private & anonymous'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
    });
  });
}
