import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/utils/call_signal_interpreter.dart';

void main() {
  group('interpretCallSignal', () {
    test('null signal is none', () {
      expect(interpretCallSignal(null, mySenderId: 'A'), CallSignalEvent.none);
    });

    test('own write is ignored', () {
      final signal = {'from': 'A', 'status': 'ringing', 'delivered': true};
      expect(
          interpretCallSignal(signal, mySenderId: 'A'), CallSignalEvent.none);
    });

    test('ringing without delivered flag is none (still just "Calling...")', () {
      final signal = {'from': 'A', 'status': 'ringing', 'delivered': false};
      expect(
          interpretCallSignal(signal, mySenderId: 'B'), CallSignalEvent.none);
    });

    test('ringing with delivered flag is delivered', () {
      final signal = {'from': 'A', 'status': 'ringing', 'delivered': true};
      expect(interpretCallSignal(signal, mySenderId: 'B'),
          CallSignalEvent.delivered);
    });

    test('accepted status is accepted', () {
      final signal = {'from': 'A', 'status': 'accepted'};
      expect(interpretCallSignal(signal, mySenderId: 'B'),
          CallSignalEvent.accepted);
    });

    test('declined status is declined', () {
      final signal = {'from': 'A', 'status': 'declined'};
      expect(interpretCallSignal(signal, mySenderId: 'B'),
          CallSignalEvent.declined);
    });

    test('ended status is none (handled separately via onUserLeft/timeout)', () {
      final signal = {'from': 'A', 'status': 'ended'};
      expect(
          interpretCallSignal(signal, mySenderId: 'B'), CallSignalEvent.none);
    });
  });

  group('callerStatusLabel', () {
    test('defaults to Calling...', () {
      expect(
          callerStatusLabel(remoteAccepted: false, remoteDelivered: false),
          'Calling...');
    });

    test('shows Ringing... once delivered', () {
      expect(
          callerStatusLabel(remoteAccepted: false, remoteDelivered: true),
          'Ringing...');
    });

    test('shows Connecting... once accepted, even if delivered flag lagged', () {
      expect(
          callerStatusLabel(remoteAccepted: true, remoteDelivered: false),
          'Connecting...');
    });

    test('accepted takes priority over delivered', () {
      expect(
          callerStatusLabel(remoteAccepted: true, remoteDelivered: true),
          'Connecting...');
    });
  });
}
