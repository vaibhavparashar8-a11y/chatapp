import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/models/ping.dart';
import 'package:chatapp/screens/todo_screen.dart';
import 'package:chatapp/services/device_service.dart';
import 'package:chatapp/services/notification_service.dart';
import 'package:chatapp/services/ping_service.dart';
import 'package:chatapp/services/reminder_service.dart';
import 'package:chatapp/services/remote_config_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationService.testMode = true;
    RemoteConfigService.testMode = true;
    ReminderService.testMode = true;
    DeviceService.testMode = true;
    PingService.testMode = true;
    mySenderId = 'A';
  });

  tearDown(() {
    NotificationService.testMode = false;
    RemoteConfigService.testMode = false;
    ReminderService.testMode = false;
    DeviceService.testMode = false;
    PingService.testMode = false;
    PingService.pingOverride = null;
    PingService.roomOverride = null;
    mySenderId = '';
  });

  Widget wrap() => const MaterialApp(home: TodoScreen());

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('My Tasks'));
    await tester.pumpAndSettle();
  }

  testWidgets('long-pressing the title opens the device check', (tester) async {
    await openDialog(tester);
    expect(find.text('Device check'), findsOneWidget);
    expect(find.text('Send ping'), findsOneWidget);
  });

  testWidgets('shows what the room doc knows about both phones',
      (tester) async {
    PingService.roomOverride = DeviceCheck(
      me: const DeviceRecord(claimed: true, hasFcmToken: true),
      them: DeviceRecord(
        claimed: true,
        hasFcmToken: false,
        appLastOpened: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    );
    await openDialog(tester);

    expect(find.text('This phone (A)'), findsOneWidget);
    expect(find.text('Other phone (B)'), findsOneWidget);
    expect(find.text('Installed (role claimed)'), findsNWidgets(2));
    expect(find.textContaining('Last opened today at'), findsOneWidget);
    // This phone has never opened anything in this fixture.
    expect(find.text('Never opened the app'), findsOneWidget);
  });

  testWidgets('a reply reports who answered and how long it took',
      (tester) async {
    PingService.pingOverride = const PingResult(
      outcome: PingOutcome.replied,
      roundTrip: Duration(milliseconds: 380),
      repliedBy: 'B',
      via: PingReplyVia.background,
    );
    await openDialog(tester);
    await tester.tap(find.text('Send ping'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Phone B replied in 380ms'), findsOneWidget);
    expect(find.textContaining('woken by the push'), findsOneWidget);
    // The button invites a re-run once a result is on screen.
    expect(find.text('Ping again'), findsOneWidget);
  });

  testWidgets('no reply is reported as the other phone being unreachable',
      (tester) async {
    PingService.pingOverride =
        const PingResult(outcome: PingOutcome.timedOut);
    await openDialog(tester);
    await tester.tap(find.text('Send ping'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No reply in'), findsOneWidget);
    expect(find.textContaining('Phone B is uninstalled'), findsOneWidget);
  });

  testWidgets('a send failure is distinguished from a silent other phone',
      (tester) async {
    PingService.pingOverride = const PingResult(
      outcome: PingOutcome.failed,
      error: 'permission-denied',
    );
    await openDialog(tester);
    await tester.tap(find.text('Send ping'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not send the ping'), findsOneWidget);
  });
}
