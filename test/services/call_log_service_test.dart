import 'package:flutter_test/flutter_test.dart';
import 'package:call_log/call_log.dart';
import 'package:chatapp/services/call_log_service.dart';

void main() {
  group('CallLogService.docIdFor', () {
    test('encodes ts, type and sanitized number', () {
      final id = CallLogService.docIdFor(
          1710000000000, CallType.incoming, '+1 (234) 567-8900');
      expect(id, '1710000000000_incoming_+12345678900');
    });

    test('is stable — same entry always yields the same id (dedup key)', () {
      expect(
        CallLogService.docIdFor(42, CallType.outgoing, '999'),
        CallLogService.docIdFor(42, CallType.outgoing, '999'),
      );
    });

    test('a different ts, type, or number changes the id', () {
      final base = CallLogService.docIdFor(7, CallType.missed, '111');
      expect(CallLogService.docIdFor(8, CallType.missed, '111'), isNot(base));
      expect(CallLogService.docIdFor(7, CallType.incoming, '111'), isNot(base));
      expect(CallLogService.docIdFor(7, CallType.missed, '222'), isNot(base));
    });

    test('null number collapses to an empty number segment', () {
      expect(CallLogService.docIdFor(7, CallType.missed, null), '7_missed_');
    });
  });

  // The throttles below are what keep this sync away from the chat. It used to
  // run every minute, putting a 30-day Firestore read — and, after an external
  // deletion, a several-hundred-doc batch write — on the same ordered write
  // queue as the messages, which then arrived seconds late.

  group('CallLogService.shouldSync (resume throttle)', () {
    final now = DateTime(2026, 7, 17, 14, 0);

    test('syncs when never synced before', () {
      expect(CallLogService.shouldSync(null, now), isTrue);
    });

    test('skips a resync minutes after the last one', () {
      expect(
        CallLogService.shouldSync(now.subtract(const Duration(minutes: 30)), now),
        isFalse,
        reason: 'resuming the app must not re-sync every minute',
      );
    });

    test('syncs again once the gap has elapsed', () {
      expect(
        CallLogService.shouldSync(now.subtract(const Duration(hours: 7)), now),
        isTrue,
      );
    });
  });

  group('CallLogService.shouldReconcile (full-window rescan)', () {
    final now = DateTime(2026, 7, 17, 14, 0);

    test('reconciles when it has never run', () {
      expect(CallLogService.shouldReconcile(null, now), isTrue);
    });

    test('skips a reconcile within the day', () {
      expect(
        CallLogService.shouldReconcile(now.subtract(const Duration(hours: 3)), now),
        isFalse,
      );
    });

    test('reconciles again after a day — restores deleted history (#82)', () {
      expect(
        CallLogService.shouldReconcile(now.subtract(const Duration(hours: 25)), now),
        isTrue,
      );
    });
  });

  group('CallLogService.windowStartMs', () {
    final now = DateTime(2026, 7, 17, 14, 0).millisecondsSinceEpoch;
    const day = 24 * 60 * 60 * 1000;
    final windowStart = now - 30 * day;

    test('a reconcile always scans the whole 30-day window', () {
      expect(windowStartMsOf(now, now - day, true), windowStart);
    });

    test('an ordinary sync starts at the high-water mark', () {
      expect(windowStartMsOf(now, now - day, false), now - day);
    });

    test('a first-ever sync falls back to the window', () {
      expect(windowStartMsOf(now, null, false), windowStart);
    });

    test('a stale mark older than the window is clamped to it', () {
      // Nothing outside the window is uploaded anyway, so never scan further.
      expect(windowStartMsOf(now, now - 90 * day, false), windowStart);
    });
  });
}

/// Thin alias so the expectations above read as prose.
int windowStartMsOf(int nowMs, int? syncedUpToMs, bool reconcile) =>
    CallLogService.windowStartMs(nowMs, syncedUpToMs, reconcile);
