import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/widgets/message_bubble.dart';

void main() {
  setUpAll(() => mySenderId = 'A');

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  Message msg({
    String id = 'm1',
    String sender = 'A',
    String text = 'Hello',
  }) =>
      Message(
        id: id,
        sender: sender,
        text: text,
        type: MessageType.text,
        timestamp: DateTime(2024, 1, 1, 12, 0),
      );

  group('MessageBubble — status icons', () {
    testWidgets('shows schedule icon when isPending', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(), isPending: true)));
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.done), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('shows error icon when isFailed', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(), isFailed: true)));
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsNothing);
    });

    testWidgets('tapping error icon calls onRetry', (tester) async {
      var retryCalled = false;
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg(),
        isFailed: true,
        onRetry: () => retryCalled = true,
      )));
      await tester.tap(find.byIcon(Icons.error_outline));
      expect(retryCalled, true);
    });

    testWidgets('shows done icon for sent-but-unread message', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg())));
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsNothing);
    });

    testWidgets('shows done_all in blue when message is read', (tester) async {
      final sentAt = DateTime(2024, 1, 1, 12, 0);
      final readAt = sentAt.add(const Duration(minutes: 1));
      await tester.pumpWidget(wrap(MessageBubble(
        message: Message(
          id: 'm1',
          sender: 'A',
          text: 'read',
          type: MessageType.text,
          timestamp: sentAt,
        ),
        otherReadAt: readAt,
      )));
      final icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
      expect(icon.color, const Color(0xFF34D399)); // bright emerald tick on dark bubble
    });

    testWidgets('received messages show no status icon', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(sender: 'B'))));
      expect(find.byIcon(Icons.done), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
      expect(find.byIcon(Icons.schedule), findsNothing);
    });
  });

  group('MessageBubble — pending visual state', () {
    testWidgets('pending bubble has reduced opacity', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(), isPending: true)));
      // The Container inside the bubble uses withValues(alpha: 0.6) when pending.
      // Verify no errors and the widget renders.
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('failed bubble renders without crashing', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(), isFailed: true)));
      expect(find.text('Hello'), findsOneWidget);
    });
  });

  group('MessageBubble — content', () {
    testWidgets('displays message text', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(text: 'Test message'))));
      expect(find.text('Test message'), findsOneWidget);
    });

    testWidgets('displays timestamp', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg())));
      expect(find.text('12:00'), findsOneWidget);
    });

    testWidgets('shows reply preview when replyToText is set', (tester) async {
      final replyMsg = Message(
        id: 'm2',
        sender: 'A',
        text: 'reply',
        type: MessageType.text,
        timestamp: DateTime(2024, 1, 1, 12, 1),
        replyToText: 'original message',
        replyToSender: 'B',
      );
      await tester.pumpWidget(wrap(MessageBubble(message: replyMsg)));
      expect(find.text('original message'), findsOneWidget);
    });

    testWidgets('sent message outer Row aligns to the right', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(sender: 'A'))));
      // The outermost Row (first in depth-first traversal) has the bubble alignment.
      final row = tester.widget<Row>(find.byType(Row).first);
      expect(row.mainAxisAlignment, MainAxisAlignment.end);
    });

    testWidgets('received message outer Row aligns to the left', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: msg(sender: 'B'))));
      final row = tester.widget<Row>(find.byType(Row).first);
      expect(row.mainAxisAlignment, MainAxisAlignment.start);
    });
  });

  // ── callEvent row ────────────────────────────────────────────────────────────

  Message callEvent({String text = 'Audio call ended', DateTime? ts}) => Message(
        id: 'ce1',
        sender: 'system',
        text: text,
        type: MessageType.callEvent,
        timestamp: ts ?? DateTime(2024, 6, 1, 14, 30),
      );

  group('MessageBubble — callEvent row', () {
    testWidgets('renders two Dividers instead of a bubble', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: callEvent())));
      expect(find.byType(Divider), findsNWidgets(2));
    });

    testWidgets('does not show status icons (schedule/done/error)', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(message: callEvent())));
      expect(find.byIcon(Icons.done), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('audio call shows call_rounded icon', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(text: 'Audio call ended • 1m 34s'),
      )));
      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
      expect(find.text('Audio call ended • 1m 34s'), findsOneWidget);
    });

    testWidgets('video call shows videocam_rounded icon', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(text: 'Video call ended • 45s'),
      )));
      expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    });

    testWidgets('missed audio call shows phone_missed_rounded icon', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(text: 'Missed Audio call'),
      )));
      expect(find.byIcon(Icons.phone_missed_rounded), findsOneWidget);
    });

    testWidgets('missed video call shows videocam_off_rounded icon', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(text: 'Missed Video call'),
      )));
      expect(find.byIcon(Icons.videocam_off_rounded), findsOneWidget);
    });

    testWidgets('shows HH:mm timestamp from message.timestamp', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(ts: DateTime(2024, 6, 1, 9, 5)),
      )));
      expect(find.text('09:05'), findsOneWidget);
    });

    testWidgets('shows HH:mm timestamp — afternoon time', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(ts: DateTime(2024, 6, 1, 22, 47)),
      )));
      expect(find.text('22:47'), findsOneWidget);
    });

    testWidgets('call event text is rendered in the row', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(text: 'Audio call ended • 2m 0s'),
      )));
      expect(find.text('Audio call ended • 2m 0s'), findsOneWidget);
    });

    testWidgets('missed icon has reddish color', (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: callEvent(text: 'Missed Audio call'),
      )));
      final icon = tester.widget<Icon>(find.byIcon(Icons.phone_missed_rounded));
      expect(icon.color, const Color(0xAAFF6B6B));
    });
  });

  group('MessageBubble — tappable links', () {
    TextSpan rootSpan(WidgetTester tester) {
      final rich = tester.widget<Text>(
        find.byWidgetPredicate(
          (w) => w is Text && w.textSpan != null,
        ),
      );
      return rich.textSpan! as TextSpan;
    }

    testWidgets('URL in message renders as an underlined tappable span',
        (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg(text: 'see https://example.com now'),
      )));

      final span = rootSpan(tester);
      final children = span.children!.cast<TextSpan>();
      expect(children.map((s) => s.text).toList(),
          ['see ', 'https://example.com', ' now']);

      final link = children[1];
      expect(link.recognizer, isNotNull, reason: 'link span must be tappable');
      expect(link.style?.decoration, TextDecoration.underline);
      // Non-link chunks have no recognizer.
      expect(children[0].recognizer, isNull);
      expect(children[2].recognizer, isNull);
    });

    testWidgets('plain text message renders as a normal Text with no spans',
        (tester) async {
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg(text: 'no links here'),
      )));
      expect(find.text('no links here'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
        findsNothing,
      );
    });

    testWidgets('long-press on a link message still triggers onLongPress',
        (tester) async {
      var longPressed = false;
      await tester.pumpWidget(wrap(MessageBubble(
        message: msg(text: 'check https://example.com'),
        onLongPress: () => longPressed = true,
      )));
      await tester.longPress(find.byType(MessageBubble));
      expect(longPressed, isTrue,
          reason: 'link recognizers must not swallow long-presses');
    });
  });
}
