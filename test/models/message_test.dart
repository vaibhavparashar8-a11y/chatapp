import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/message.dart';

void main() {
  group('Message', () {
    final baseMap = {
      'sender': 'A',
      'text': 'Hello',
      'type': 'text',
      'mediaUrl': null,
      'fileName': null,
      'fileSize': null,
      'timestamp': _FakeTimestamp(DateTime(2024, 6, 1, 10, 30)),
      'replyToId': null,
      'replyToText': null,
      'replyToSender': null,
      'clientId': 'client-abc',
    };

    test('fromMap deserializes all fields correctly', () {
      final msg = Message.fromMap(baseMap, 'doc-1');

      expect(msg.id, 'doc-1');
      expect(msg.sender, 'A');
      expect(msg.text, 'Hello');
      expect(msg.type, MessageType.text);
      expect(msg.timestamp, DateTime(2024, 6, 1, 10, 30));
      expect(msg.clientId, 'client-abc');
    });

    test('fromMap handles unknown type gracefully', () {
      final msg = Message.fromMap({...baseMap, 'type': 'unknown_type'}, 'x');
      expect(msg.type, MessageType.text); // fallback
    });

    test('fromMap handles missing timestamp', () {
      final msg = Message.fromMap({...baseMap, 'timestamp': null}, 'x');
      // Should not throw; timestamp defaults to DateTime.now()
      expect(msg.timestamp, isA<DateTime>());
    });

    test('toMap includes clientId when set', () {
      final msg = Message(
        id: '1',
        sender: 'A',
        text: 'Hi',
        type: MessageType.text,
        timestamp: DateTime(2024, 1, 1),
        clientId: 'cid-xyz',
      );
      final map = msg.toMap();
      expect(map['clientId'], 'cid-xyz');
    });

    test('toMap omits clientId when null', () {
      final msg = Message(
        id: '1',
        sender: 'A',
        text: 'Hi',
        type: MessageType.text,
        timestamp: DateTime(2024, 1, 1),
      );
      final map = msg.toMap();
      expect(map.containsKey('clientId'), false);
    });

    test('toMap omits optional reply fields when null', () {
      final msg = Message(
        id: '1',
        sender: 'A',
        text: 'Hi',
        type: MessageType.text,
        timestamp: DateTime(2024, 1, 1),
      );
      final map = msg.toMap();
      expect(map.containsKey('replyToId'), false);
      expect(map.containsKey('replyToText'), false);
      expect(map.containsKey('replyToSender'), false);
    });

    test('toMap includes reply fields when set', () {
      final msg = Message(
        id: '1',
        sender: 'A',
        text: 'reply',
        type: MessageType.text,
        timestamp: DateTime(2024, 1, 1),
        replyToId: 'orig-id',
        replyToText: 'original',
        replyToSender: 'B',
      );
      final map = msg.toMap();
      expect(map['replyToId'], 'orig-id');
      expect(map['replyToText'], 'original');
      expect(map['replyToSender'], 'B');
    });

    test('fromMap deserializes iv field for legacy encrypted messages', () {
      final msg = Message.fromMap({...baseMap, 'iv': 'base64nonce=='}, 'x');
      expect(msg.iv, 'base64nonce==');
    });

    test('fromMap leaves iv null for new plaintext messages', () {
      final msg = Message.fromMap(baseMap, 'x');
      expect(msg.iv, isNull);
    });

    test('toMap omits iv when null (new messages never write iv)', () {
      final msg = Message(
        id: '1', sender: 'A', text: 'hi',
        type: MessageType.text, timestamp: DateTime(2024, 1, 1),
      );
      expect(msg.toMap().containsKey('iv'), false);
    });

    test('toMap includes iv when present (round-trip of legacy doc)', () {
      final msg = Message(
        id: '1', sender: 'A', text: 'cipher',
        type: MessageType.text, timestamp: DateTime(2024, 1, 1),
        iv: 'abc123==',
      );
      expect(msg.toMap()['iv'], 'abc123==');
    });

    for (final type in MessageType.values) {
      test('round-trips MessageType.$type', () {
        final msg = Message(
          id: '1',
          sender: 'A',
          text: '',
          type: type,
          timestamp: DateTime(2024, 1, 1),
        );
        final map = msg.toMap();
        final restored = Message.fromMap({
          ...map,
          'timestamp': _FakeTimestamp(DateTime(2024, 1, 1)),
        }, '1');
        expect(restored.type, type);
      });
    }
  });
}

/// Minimal stand-in for Firestore Timestamp — exposes only .toDate().
class _FakeTimestamp {
  final DateTime _dt;
  const _FakeTimestamp(this._dt);
  DateTime toDate() => _dt;
}
