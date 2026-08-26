// test/features/call/video_quality_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/features/call/video_quality.dart';

// Agora QualityType values used as plain ints.
const excellent = 1;
const good = 2;
const poor = 3;
const bad = 4;
const down = 6;
const unknown = 0;

/// Feeds [count] identical reports and returns every level change emitted.
List<VideoQualityLevel> feed(
  VideoQualityController c,
  int quality,
  int count,
) {
  final changes = <VideoQualityLevel>[];
  for (var i = 0; i < count; i++) {
    final next = c.onNetworkQuality(quality, quality);
    if (next != null) changes.add(next);
  }
  return changes;
}

void main() {
  group('VideoQualityController', () {
    test('starts on the standard rung', () {
      expect(VideoQualityController().level, VideoQualityLevel.standard);
    });

    test('ignores reports while both directions are unknown', () {
      final c = VideoQualityController();
      expect(feed(c, unknown, 10), isEmpty);
      expect(c.level, VideoQualityLevel.standard);
    });

    test('climbs to high after $kUpSamples good reports', () {
      final c = VideoQualityController();
      expect(feed(c, excellent, kUpSamples - 1), isEmpty);
      expect(c.onNetworkQuality(excellent, excellent), VideoQualityLevel.high);
      expect(c.level, VideoQualityLevel.high);
    });

    test('stays at high once there — no further changes emitted', () {
      final c = VideoQualityController(level: VideoQualityLevel.high);
      expect(feed(c, good, kUpSamples * 3), isEmpty);
      expect(c.level, VideoQualityLevel.high);
    });

    test('drops one rung after $kDownSamples bad reports', () {
      final c = VideoQualityController(level: VideoQualityLevel.high);
      expect(feed(c, bad, kDownSamples), [VideoQualityLevel.standard]);
      expect(feed(c, bad, kDownSamples), [VideoQualityLevel.low]);
      // Already at the bottom — nothing left to give.
      expect(feed(c, down, kDownSamples * 2), isEmpty);
      expect(c.level, VideoQualityLevel.low);
    });

    test('poor holds the current rung and resets both streaks', () {
      final c = VideoQualityController();
      feed(c, excellent, kUpSamples - 1);
      expect(c.onNetworkQuality(poor, poor), isNull);
      // Streak was cleared, so one more good report must not be enough.
      expect(c.onNetworkQuality(excellent, excellent), isNull);
      expect(c.level, VideoQualityLevel.standard);
    });

    test('a single bad report does not undo a good streak prematurely', () {
      final c = VideoQualityController();
      feed(c, excellent, kUpSamples - 1);
      expect(c.onNetworkQuality(bad, bad), isNull); // good streak reset
      expect(feed(c, excellent, kUpSamples - 1), isEmpty);
      expect(c.level, VideoQualityLevel.standard);
    });

    test('the worst of the two directions decides', () {
      final c = VideoQualityController(level: VideoQualityLevel.high);
      // Uplink excellent but downlink bad still counts as bad.
      expect(c.onNetworkQuality(excellent, bad), isNull);
      expect(c.onNetworkQuality(excellent, bad), VideoQualityLevel.standard);
    });

    test('every level has a profile, and they increase monotonically', () {
      for (final level in VideoQualityLevel.values) {
        expect(kVideoQualityProfiles[level], isNotNull);
      }
      final low = kVideoQualityProfiles[VideoQualityLevel.low]!;
      final std = kVideoQualityProfiles[VideoQualityLevel.standard]!;
      final high = kVideoQualityProfiles[VideoQualityLevel.high]!;
      expect(low.width, lessThan(std.width));
      expect(std.width, lessThan(high.width));
      expect(low.bitrate, lessThan(std.bitrate));
      expect(std.bitrate, lessThan(high.bitrate));
      expect(high.height, 720); // HD on a good connection
    });
  });
}
