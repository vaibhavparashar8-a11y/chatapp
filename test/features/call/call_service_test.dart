import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/features/call/agora_call_engine.dart';
import 'package:chatapp/features/call/call_service.dart';
import 'package:chatapp/features/call/webrtc_call_engine.dart';

void main() {
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
