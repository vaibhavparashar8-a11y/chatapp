import 'package:chatapp/constants.dart';
import 'package:chatapp/features/call/call_service.dart';
import 'package:chatapp/features/call/end_minimized_call.dart';
import 'package:chatapp/services/log_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who logs a call that ended, and how many times.
///
/// Both phones read the same room, so exactly one write must happen per call —
/// no matter which side hung up or which surface they were looking at.
void main() {
  late List<String> events;
  late List<String> statuses;
  late int leaves;

  setUpAll(() => LogService.testMode = true);
  tearDownAll(() => LogService.testMode = false);

  setUp(() {
    events = [];
    statuses = [];
    leaves = 0;
    resetEndMinimizedCallGuard();
    sendCallEventOverride = (text) async => events.add(text);
    updateCallStatusOverride = (status) async => statuses.add(status);
    leaveCallOverride = () async {
      leaves++;
      CallService.inCall = false;
    };

    CallService.inCall = true;
    CallService.connectedAt = DateTime.now().subtract(const Duration(seconds: 65));
    isCallVideo = true;
    isCallCaller = true;
    callActiveNotifier.value = true;
  });

  tearDown(() {
    sendCallEventOverride = null;
    updateCallStatusOverride = null;
    leaveCallOverride = null;
    CallService.inCall = false;
    CallService.connectedAt = null;
    callActiveNotifier.value = false;
  });

  test('the caller logs the call, marks it ended and releases the engine',
      () async {
    await endMinimizedCall();

    expect(events, ['Video call ended • 01:05']);
    expect(statuses, ['ended']);
    expect(leaves, 1);
    expect(callActiveNotifier.value, isFalse);
  });

  // The callee's own hang-up writes nothing: the caller's side logs it when it
  // sees the remote leave. Two writes would double the entry.
  test('the callee does not log, but still tears down', () async {
    isCallCaller = false;

    await endMinimizedCall();

    expect(events, isEmpty);
    expect(statuses, ['ended']);
    expect(leaves, 1);
  });

  // The regression this file exists for: the callee hangs up while the CALLER
  // is minimized. CallScreen._minimize routes that through here, so the caller
  // still logs it — it used to tear down silently and the call vanished.
  test('a remote hang-up on the caller side still logs the call', () async {
    // Exactly what _minimize installs as CallService.onCallEnded.
    final onCallEnded = () => endMinimizedCall();
    await onCallEnded();

    expect(events, hasLength(1));
    expect(events.single, startsWith('Video call ended'));
  });

  test('an audio call is logged as an audio call', () async {
    isCallVideo = false;

    await endMinimizedCall();

    expect(events.single, startsWith('Audio call ended'));
  });

  test('a call that never connected is logged as missed', () async {
    CallService.connectedAt = null;

    await endMinimizedCall();

    expect(events, ['Missed Video call']);
  });

  test('two teardowns racing still log the call once', () async {
    await Future.wait([endMinimizedCall(), endMinimizedCall()]);

    expect(events, hasLength(1));
    expect(leaves, 1);
  });

  test('with no live engine it only clears the call UI', () async {
    CallService.inCall = false;

    await endMinimizedCall();

    expect(events, isEmpty);
    expect(leaves, 0);
    expect(callActiveNotifier.value, isFalse);
  });
}
