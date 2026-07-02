import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/screens/calls_screen.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0F1E),
        body: child,
      ),
    );

/// Creates a [CallsScreen] backed by a single-shot list (no Firebase needed).
Widget screen(
  List<Message> calls, {
  void Function(bool)? onStartCall,
}) {
  final ctrl = StreamController<List<Message>>();
  ctrl.add(calls);
  return wrap(CallsScreen(
    onStartCall: onStartCall ?? (_) {},
    callsStream: ctrl.stream,
  ));
}

Message callEvent({
  String text = 'Audio call ended • 1m 34s',
  String? callerId,
  DateTime? ts,
}) =>
    Message(
      id: 'ce-${text.hashCode}',
      sender: 'system',
      text: text,
      type: MessageType.callEvent,
      timestamp: ts ?? DateTime(2024, 6, 1, 14, 30),
      callerId: callerId,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() => mySenderId = 'A');

  // ── Empty state ─────────────────────────────────────────────────────────────

  group('CallsScreen — empty state', () {
    testWidgets('shows No calls yet and call icon', (tester) async {
      await tester.pumpWidget(screen([]));
      await tester.pump();
      expect(find.text('No calls yet'), findsOneWidget);
      expect(find.byIcon(Icons.call_outlined), findsOneWidget);
    });
  });

  // ── Call type ───────────────────────────────────────────────────────────────

  group('CallsScreen — call type icons', () {
    testWidgets('audio call shows call_rounded icon and "Audio call" title',
        (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Audio call ended • 1m 34s', callerId: 'A'),
      ]));
      await tester.pump();
      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
      expect(find.text('Audio call'), findsOneWidget);
    });

    testWidgets('video call shows videocam_rounded icon and "Video call" title',
        (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Video call ended • 45s', callerId: 'A'),
      ]));
      await tester.pump();
      expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
      expect(find.text('Video call'), findsOneWidget);
    });

    testWidgets('duration text appears in the tile', (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Audio call ended • 2m 10s', callerId: 'A'),
      ]));
      await tester.pump();
      expect(find.text('2m 10s'), findsOneWidget);
    });
  });

  // ── Missed calls ─────────────────────────────────────────────────────────────

  group('CallsScreen — missed calls', () {
    testWidgets('missed audio shows call_missed_rounded direction icon and red title',
        (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Missed Audio call', callerId: 'B'),
      ]));
      await tester.pump();
      expect(find.byIcon(Icons.call_missed_rounded), findsOneWidget);
      final title = tester.widget<Text>(find.text('Audio call'));
      expect(title.style?.color, const Color(0xFFFF6B6B));
    });

    testWidgets('missed video shows videocam_rounded leading icon',
        (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Missed Video call', callerId: 'B'),
      ]));
      await tester.pump();
      expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
      final title = tester.widget<Text>(find.text('Video call'));
      expect(title.style?.color, const Color(0xFFFF6B6B));
    });
  });

  // ── Direction ───────────────────────────────────────────────────────────────

  group('CallsScreen — direction labels', () {
    testWidgets('callerId == mySenderId shows Outgoing + call_made icon',
        (tester) async {
      // mySenderId = 'A', callerId = 'A' → outgoing
      await tester.pumpWidget(screen([
        callEvent(text: 'Audio call ended • 30s', callerId: 'A'),
      ]));
      await tester.pump();
      expect(find.text('Outgoing'), findsOneWidget);
      expect(find.byIcon(Icons.call_made_rounded), findsOneWidget);
    });

    testWidgets('callerId != mySenderId shows Incoming + call_received icon',
        (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Audio call ended • 30s', callerId: 'B'),
      ]));
      await tester.pump();
      expect(find.text('Incoming'), findsOneWidget);
      expect(find.byIcon(Icons.call_received_rounded), findsOneWidget);
    });

    testWidgets('missed by other shows Missed label', (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Missed Audio call', callerId: 'B'),
      ]));
      await tester.pump();
      expect(find.text('Missed'), findsOneWidget);
    });

    testWidgets('missing callerId shows no direction label', (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Audio call ended • 1m 0s'), // no callerId
      ]));
      await tester.pump();
      expect(find.text('Outgoing'), findsNothing);
      expect(find.text('Incoming'), findsNothing);
      expect(find.text('Missed'), findsNothing);
      expect(find.text('Audio call'), findsOneWidget); // still shows type
    });
  });

  // ── Callback button ─────────────────────────────────────────────────────────

  group('CallsScreen — callback button', () {
    testWidgets('audio tile button calls onStartCall(false)', (tester) async {
      bool? calledWith;
      await tester.pumpWidget(screen(
        [callEvent(text: 'Audio call ended • 10s', callerId: 'A')],
        onStartCall: (v) => calledWith = v,
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.call_outlined));
      expect(calledWith, false);
    });

    testWidgets('video tile button calls onStartCall(true)', (tester) async {
      bool? calledWith;
      await tester.pumpWidget(screen(
        [callEvent(text: 'Video call ended • 10s', callerId: 'A')],
        onStartCall: (v) => calledWith = v,
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.videocam_outlined));
      expect(calledWith, true);
    });
  });

  // ── Timestamp formatting ────────────────────────────────────────────────────

  group('CallsScreen — timestamp display', () {
    testWidgets('call today shows "Today,"', (tester) async {
      await tester.pumpWidget(screen([callEvent(ts: DateTime.now())]));
      await tester.pump();
      expect(find.textContaining('Today,'), findsOneWidget);
    });

    testWidgets('call yesterday shows "Yesterday,"', (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await tester.pumpWidget(screen([callEvent(ts: yesterday)]));
      await tester.pump();
      expect(find.textContaining('Yesterday,'), findsOneWidget);
    });

    testWidgets('call 10 days ago does not show Today or Yesterday',
        (tester) async {
      final old = DateTime.now().subtract(const Duration(days: 10));
      await tester.pumpWidget(screen([callEvent(ts: old)]));
      await tester.pump();
      expect(find.textContaining('Today,'), findsNothing);
      expect(find.textContaining('Yesterday,'), findsNothing);
    });
  });

  // ── Multiple entries ────────────────────────────────────────────────────────

  group('CallsScreen — list', () {
    testWidgets('renders all provided entries', (tester) async {
      await tester.pumpWidget(screen([
        callEvent(text: 'Audio call ended • 1m 0s', callerId: 'A'),
        callEvent(text: 'Video call ended • 30s', callerId: 'B'),
        callEvent(text: 'Missed Audio call', callerId: 'B'),
      ]));
      await tester.pump();
      expect(find.text('Audio call'), findsNWidgets(2)); // ended + missed
      expect(find.text('Video call'), findsOneWidget);
    });
  });
}
