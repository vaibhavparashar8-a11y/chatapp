import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/ping.dart';
import 'package:chatapp/services/ping_service.dart';

void main() {
  group('PingService.parseRoom', () {
    final room = <String, dynamic>{
      'roleAssignments': {'A': 'android-id-A', 'B': 'android-id-B'},
      'fcmTokens': {'A': 'token-A'},
      'appLastOpened': {'A': DateTime(2026, 7, 15, 9)},
      'todoLastOpened': {
        'A': DateTime(2026, 7, 15, 11),
        'B': DateTime(2026, 7, 14, 8),
      },
    };

    test('reads each role from the room doc, from the caller\'s point of view',
        () {
      final check = PingService.parseRoom(room, me: 'A');
      expect(check.me.claimed, isTrue);
      expect(check.me.hasFcmToken, isTrue);
      expect(check.them.claimed, isTrue);
      // B has never registered a push token — a ping to B can't be delivered.
      expect(check.them.hasFcmToken, isFalse);
      expect(check.bothClaimed, isTrue);
    });

    test('swaps me/them when the other phone asks', () {
      final check = PingService.parseRoom(room, me: 'B');
      expect(check.me.hasFcmToken, isFalse);
      expect(check.them.hasFcmToken, isTrue);
    });

    test('lastSeen takes the later of the chat and todo opens', () {
      final check = PingService.parseRoom(room, me: 'A');
      expect(check.me.lastSeen, DateTime(2026, 7, 15, 11));
      // B only ever opened the todo list.
      expect(check.them.lastSeen, DateTime(2026, 7, 14, 8));
    });

    test('an empty room means neither phone has ever claimed a role', () {
      final check = PingService.parseRoom(const {}, me: 'A');
      expect(check.me.claimed, isFalse);
      expect(check.them.claimed, isFalse);
      expect(check.bothClaimed, isFalse);
      expect(check.me.lastSeen, isNull);
    });

    test('an empty assignment string does not count as installed', () {
      final check = PingService.parseRoom(const {
        'roleAssignments': {'A': ''},
      }, me: 'A');
      expect(check.me.claimed, isFalse);
    });
  });

  group('PingService.parseReply', () {
    const elapsed = Duration(milliseconds: 420);

    test('a doc with no reply yet is a timeout, not a success', () {
      expect(PingService.parseReply(null, elapsed).outcome,
          PingOutcome.timedOut);
      expect(
        PingService.parseReply(const {'from': 'A'}, elapsed).outcome,
        PingOutcome.timedOut,
      );
    });

    test('a reply carries the responder, the round trip and how it woke', () {
      final result = PingService.parseReply(
        const {'repliedBy': 'B', 'replyVia': 'background'},
        elapsed,
      );
      expect(result.replied, isTrue);
      expect(result.repliedBy, 'B');
      expect(result.roundTrip, elapsed);
      expect(result.via, PingReplyVia.background);
    });

    test('an unknown replyVia degrades instead of throwing', () {
      // Written by an older build that predates the via field.
      final result =
          PingService.parseReply(const {'repliedBy': 'A'}, elapsed);
      expect(result.replied, isTrue);
      expect(result.via, PingReplyVia.unknown);
    });
  });

  group('PingService.ping', () {
    tearDown(() {
      PingService.pingOverride = null;
      PingService.testMode = false;
    });

    test('never touches Firestore in testMode', () async {
      PingService.testMode = true;
      final result = await PingService.ping();
      expect(result.outcome, PingOutcome.failed);
    });

    test('the override wins so widgets can be driven in tests', () async {
      PingService.testMode = true;
      PingService.pingOverride =
          const PingResult(outcome: PingOutcome.replied, repliedBy: 'B');
      expect((await PingService.ping()).repliedBy, 'B');
    });
  });
}
