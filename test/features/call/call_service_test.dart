import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/features/call/agora_call_engine.dart';
import 'package:chatapp/features/call/call_service.dart';
import 'package:chatapp/features/call/webrtc_call_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallService.leaveCall', () {
    const channel = MethodChannel('com.example.chatapp/call');
    final nativeCalls = <String>[];

    setUp(() {
      nativeCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call.method);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // The foreground-service notification used to be stopped only by
    // CallScreen, so teardowns that bypassed it (mini bar / floating overlay
    // hang-up, CallScreen disposed) left "MyTask — Running" in the tray.
    test('stops the foreground service on every teardown path', () async {
      CallService.inCall = true;
      await CallService.leaveCall();
      expect(nativeCalls, contains('stopForeground'));
    });

    test('clears the call state so the next call starts clean', () async {
      CallService.inCall = true;
      CallService.connectedAt = DateTime.now();
      CallService.currentRemoteUid = 42;
      CallService.isMuted = true;
      callActiveNotifier.value = true;

      await CallService.leaveCall();

      expect(CallService.inCall, isFalse);
      expect(CallService.connectedAt, isNull);
      expect(CallService.currentRemoteUid, isNull);
      expect(CallService.isMuted, isFalse);
      expect(callActiveNotifier.value, isFalse);
    });
  });

  group('CallService.createEngineForBackend', () {
    test('"webrtc" selects the peer-to-peer engine', () {
      expect(CallService.createEngineForBackend('webrtc'),
          isA<WebRtcCallEngine>());
    });

    test('"agora" selects the Agora engine', () {
      expect(
          CallService.createEngineForBackend('agora'), isA<AgoraCallEngine>());
    });

    test('is case/whitespace tolerant', () {
      expect(CallService.createEngineForBackend('  WebRTC '),
          isA<WebRtcCallEngine>());
    });

    // The important safety property: a blank or typo'd Remote Config value must
    // never leave calling without a backend — it falls back to Agora.
    test('unknown or empty value falls back to Agora', () {
      expect(CallService.createEngineForBackend(''), isA<AgoraCallEngine>());
      expect(
          CallService.createEngineForBackend('wbertc'), isA<AgoraCallEngine>());
    });
  });
}
