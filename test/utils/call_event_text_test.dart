import 'package:chatapp/utils/call_event_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatCallDuration', () {
    test('pads minutes and seconds to mm:ss', () {
      expect(formatCallDuration(Duration.zero), '00:00');
      expect(formatCallDuration(const Duration(seconds: 7)), '00:07');
      expect(formatCallDuration(const Duration(minutes: 2, seconds: 5)), '02:05');
    });

    test('minutes past 99 keep counting rather than wrapping', () {
      expect(formatCallDuration(const Duration(hours: 2)), '120:00');
    });
  });

  group('callEndEventText', () {
    // The Calls tab keys off "missed"/"video" in this text — wording matters.
    test('never-connected call is logged as missed', () {
      expect(callEndEventText(isVideo: true, connectedFor: null),
          'Missed Video call');
      expect(callEndEventText(isVideo: false, connectedFor: null),
          'Missed Audio call');
    });

    test('connected call is logged with its duration', () {
      expect(
        callEndEventText(
            isVideo: false, connectedFor: const Duration(seconds: 65)),
        'Audio call ended • 01:05',
      );
      expect(
        callEndEventText(isVideo: true, connectedFor: Duration.zero),
        'Video call ended • 00:00',
      );
    });

    // Regression: a call answered and then hung up must not read as "Missed"
    // just because it was short (the old code keyed off a flag that the
    // remote-hangup path had already cleared).
    test('a one-second answered call still reads as ended, not missed', () {
      final text =
          callEndEventText(isVideo: true, connectedFor: const Duration(seconds: 1));
      expect(text, isNot(contains('Missed')));
      expect(text, 'Video call ended • 00:01');
    });
  });
}
