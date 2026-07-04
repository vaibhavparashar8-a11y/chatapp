import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/features/call/call_service.dart';
import 'package:chatapp/screens/chat_screen.dart';
import 'package:chatapp/services/device_service.dart';
import '../helpers/fake_chat_repository.dart';

/// Regression tests for the background-leave navigation in ChatScreen.
///
/// Bug history: when the app went to background DURING A FULL-SCREEN CALL,
/// ChatScreen's leave-timer ran `popUntil(isFirst)`, which popped CallScreen
/// off the stack, disposed it, and released the Agora engine — dropping the
/// call. The old guard only checked callActiveNotifier, which is true only
/// for MINIMIZED calls. CallService.inCall covers the full call lifetime.
void main() {
  late FakeChatRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceService.testMode = true;
    mySenderId = 'A';
    CallService.inCall = false;
    callActiveNotifier.value = false;
    repo = FakeChatRepository();
  });

  tearDown(() {
    DeviceService.testMode = false;
    CallService.inCall = false;
    callActiveNotifier.value = false;
    repo.close();
  });

  // AppLifecycleListener asserts on illegal jumps (e.g. resumed → paused), so
  // walk the legal state machine one step at a time.
  void goBackground(WidgetTester tester) {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void goForeground(WidgetTester tester) {
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  Future<void> pumpChatOverHome(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => ChatScreen(
                  repository: repo,
                  callSignalProvider: () => const Stream.empty(),
                ),
              )),
              child: const Text('open chat'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
  }

  testWidgets('backgrounding with no call pops back to the first route',
      (tester) async {
    await pumpChatOverHome(tester);

    goBackground(tester);
    await tester.pump(const Duration(seconds: 6));

    expect(repo.leaveCount, greaterThanOrEqualTo(1),
        reason: 'leave-timer should have fired and marked presence offline');

    // Frames are disabled while paused — the pop only renders on resume,
    // which is also when the user would see it.
    goForeground(tester);
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('open chat'), findsOneWidget);
  });

  testWidgets(
      'backgrounding during a full-screen call does NOT pop (call survives)',
      (tester) async {
    await pumpChatOverHome(tester);
    CallService.inCall = true; // set by CallService.joinCall in production

    goBackground(tester);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget,
        reason: 'popping here would dispose CallScreen and kill the call');

    goForeground(tester);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('inactive state (system overlay) during a call does NOT pop',
      (tester) async {
    await pumpChatOverHome(tester);
    CallService.inCall = true;

    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 9)); // inactive timer is 8s
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);

    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('minimized call (callActiveNotifier) still blocks the pop',
      (tester) async {
    await pumpChatOverHome(tester);
    callActiveNotifier.value = true; // minimized call bar showing

    goBackground(tester);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);

    goForeground(tester);
    await tester.pump(const Duration(seconds: 6));
  });
}
