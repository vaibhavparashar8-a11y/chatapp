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
}
