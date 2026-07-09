import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
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
}
