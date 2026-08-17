import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/features/call/call_screen.dart';
import 'package:chatapp/features/call/call_service.dart';
import 'package:chatapp/screens/chat_screen.dart';
import 'package:chatapp/services/device_service.dart';
import '../helpers/fake_chat_repository.dart';

/// Tests for the minimized-call UI state:
///  - overlay geometry persists in CallService (so the epoch-driven widget
///    reconstruction can't reset the user's chosen size/position mid-call)
///  - the mini bar / overlay require BOTH callActiveNotifier AND
///    CallService.inCall (phantom-open guard: a stale notifier alone must
///    never show call UI when no engine session is live)
void main() {
  late FakeChatRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceService.testMode = true;
    mySenderId = 'A';
    CallService.inCall = false;
    callActiveNotifier.value = false;
    isCallVideo = false;
    CallService.resetOverlayGeometry();
    repo = FakeChatRepository();
  });

  tearDown(() {
    DeviceService.testMode = false;
    CallService.inCall = false;
    callActiveNotifier.value = false;
    isCallVideo = false;
    CallService.resetOverlayGeometry();
    repo.close();
  });

  group('CallService overlay geometry', () {
    test('starts at the documented defaults', () {
      expect(CallService.overlayX, CallService.overlayDefaultX);
      expect(CallService.overlayY, CallService.overlayDefaultY);
      expect(CallService.overlayW, CallService.overlayDefaultW);
      expect(CallService.overlayH, CallService.overlayDefaultH);
    });

    test('resetOverlayGeometry restores defaults after user changes', () {
      CallService.overlayX = 200;
      CallService.overlayY = 300;
      CallService.overlayW = 260;
      CallService.overlayH = 340;
      CallService.resetOverlayGeometry();
      expect(CallService.overlayX, CallService.overlayDefaultX);
      expect(CallService.overlayY, CallService.overlayDefaultY);
      expect(CallService.overlayW, CallService.overlayDefaultW);
      expect(CallService.overlayH, CallService.overlayDefaultH);
    });
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        repository: repo,
        callSignalProvider: () => const Stream.empty(),
      ),
    ));
    await tester.pump();
  }

  group('phantom-open guard', () {
    testWidgets(
        'stale callActiveNotifier alone does NOT show the mini call bar',
        (tester) async {
      await pumpChat(tester);

      // Simulate the leftover state of an atypical call teardown: the global
      // notifier was never reset, but no engine session is live.
      callActiveNotifier.value = true;
      CallService.inCall = false;
      await tester.pump();

      expect(find.text('Tap to return to call'), findsNothing,
          reason: 'call UI must not appear without a live engine session');
    });

    testWidgets('mini call bar shows when notifier AND inCall are both true',
        (tester) async {
      await pumpChat(tester);

      callActiveNotifier.value = true;
      CallService.inCall = true;
      isCallVideo = false; // audio call → mini bar, not video overlay
      await tester.pump();

      expect(find.text('Tap to return to call'), findsOneWidget);
    });

    testWidgets('floating video overlay shows for a live video call',
        (tester) async {
      await pumpChat(tester);

      callActiveNotifier.value = true;
      CallService.inCall = true;
      isCallVideo = true;
      await tester.pump();

      expect(find.byIcon(Icons.open_in_full_rounded), findsOneWidget);
      expect(find.text('Tap to return to call'), findsNothing);
    });

    testWidgets('mini call bar disappears when the call ends', (tester) async {
      await pumpChat(tester);

      callActiveNotifier.value = true;
      CallService.inCall = true;
      await tester.pump();
      expect(find.text('Tap to return to call'), findsOneWidget);

      // leaveCall() centralizes this reset; simulate its effect.
      CallService.inCall = false;
      callActiveNotifier.value = false;
      await tester.pump();
      expect(find.text('Tap to return to call'), findsNothing);
    });
  });

  // The pip's restore-on-tap used to be hit-tested across the whole overlay,
  // resize corner included, so grabbing the corner threw the user into the
  // full-screen call. The handle now owns its own gestures.
  group('floating video overlay — resize vs restore', () {
    Future<void> pumpVideoOverlay(WidgetTester tester) async {
      await pumpChat(tester);
      callActiveNotifier.value = true;
      CallService.inCall = true;
      isCallVideo = true;
      await tester.pump();
    }

    /// Drag in small steps. A single big `tester.drag` move is swallowed as
    /// the pan recognizer's slop and never reaches onPanUpdate.
    Future<void> dragBy(WidgetTester tester, Finder from, Offset total) async {
      const steps = 8;
      final gesture = await tester.startGesture(tester.getCenter(from));
      for (var i = 0; i < steps; i++) {
        await gesture.moveBy(Offset(total.dx / steps, total.dy / steps));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
    }

    testWidgets('tapping the resize handle does not open the call screen',
        (tester) async {
      await pumpVideoOverlay(tester);

      await tester.tap(find.byIcon(Icons.open_in_full_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(CallScreen), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('dragging the handle resizes instead of navigating',
        (tester) async {
      await pumpVideoOverlay(tester);
      final startW = CallService.overlayW;
      final startH = CallService.overlayH;

      await dragBy(tester, find.byIcon(Icons.open_in_full_rounded),
          const Offset(48, 48));

      expect(CallService.overlayW, greaterThan(startW));
      expect(CallService.overlayH, greaterThan(startH));
      expect(find.byType(CallScreen), findsNothing);
    });

    testWidgets('a resize past the max size falls through to a move',
        (tester) async {
      await pumpVideoOverlay(tester);
      final startX = CallService.overlayX;

      // Far more growth than the clamps allow: the overlay maxes out partway
      // through, and the leftover deltas must not simply vanish (the old
      // "stuck when enlarged" bug).
      await dragBy(tester, find.byIcon(Icons.open_in_full_rounded),
          const Offset(400, 400));

      expect(CallService.overlayW, 260, reason: 'clamped at the max width');
      expect(CallService.overlayH, 340, reason: 'clamped at the max height');
      expect(CallService.overlayX, greaterThan(startX),
          reason: 'absorbed deltas must move the overlay instead');
      expect(find.byType(CallScreen), findsNothing);
    });
  });
}
