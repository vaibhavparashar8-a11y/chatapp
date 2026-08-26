// lib/features/call/video_quality.dart
//
// Adaptive video-quality ladder for calls. Pure Dart — no Agora/Flutter
// imports — so the escalation rules are unit-testable without an engine.

/// One rung of the ladder. `low` is what a weak mobile signal can carry,
/// `high` is 720p HD for a solid Wi-Fi connection.
enum VideoQualityLevel { low, standard, high }

/// Encoder settings for a rung.
class VideoQualityProfile {
  final int width;
  final int height;
  final int frameRate;

  /// Target bitrate in kbps.
  final int bitrate;

  const VideoQualityProfile({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.bitrate,
  });
}

const Map<VideoQualityLevel, VideoQualityProfile> kVideoQualityProfiles = {
  VideoQualityLevel.low:
      VideoQualityProfile(width: 320, height: 180, frameRate: 12, bitrate: 200),
  VideoQualityLevel.standard:
      VideoQualityProfile(width: 640, height: 360, frameRate: 15, bitrate: 600),
  VideoQualityLevel.high:
      VideoQualityProfile(width: 1280, height: 720, frameRate: 24, bitrate: 2000),
};

/// Agora `QualityType` as plain ints, so this file stays SDK-free:
/// 0 unknown · 1 excellent · 2 good · 3 poor · 4 bad · 5 very bad · 6 down.
const int _qualityUnknown = 0;
const int _qualityGood = 2;
const int _qualityBad = 4;

/// Consecutive reports needed before moving a rung. Agora reports network
/// quality about every 2 s, so dropping reacts in ~4 s while climbing waits
/// ~10 s — quick to protect a struggling call, slow to gamble on a good one.
const int kDownSamples = 2;
const int kUpSamples = 5;

/// Turns a stream of network-quality reports into ladder moves.
///
/// Calls [onNetworkQuality] with each `(txQuality, rxQuality)` pair and returns
/// the new level when it changed, or null to stay put.
class VideoQualityController {
  VideoQualityController({this.level = VideoQualityLevel.standard});

  VideoQualityLevel level;

  int _goodStreak = 0;
  int _badStreak = 0;

  VideoQualityProfile get profile => kVideoQualityProfiles[level]!;

  VideoQualityLevel? onNetworkQuality(int txQuality, int rxQuality) {
    // Ignore the report entirely until both directions have a reading —
    // "unknown" arrives for the first second or two of every call.
    if (txQuality == _qualityUnknown && rxQuality == _qualityUnknown) {
      return null;
    }
    final worst = txQuality > rxQuality ? txQuality : rxQuality;

    if (worst >= _qualityBad) {
      _badStreak++;
      _goodStreak = 0;
    } else if (worst <= _qualityGood) {
      _goodStreak++;
      _badStreak = 0;
    } else {
      // "poor" — neither good enough to climb nor bad enough to drop. Hold.
      _goodStreak = 0;
      _badStreak = 0;
      return null;
    }

    if (_badStreak >= kDownSamples) {
      _badStreak = 0;
      return _moveTo(_stepDown(level));
    }
    if (_goodStreak >= kUpSamples) {
      _goodStreak = 0;
      return _moveTo(_stepUp(level));
    }
    return null;
  }

  VideoQualityLevel? _moveTo(VideoQualityLevel next) {
    if (next == level) return null;
    level = next;
    return next;
  }

  static VideoQualityLevel _stepDown(VideoQualityLevel l) =>
      l == VideoQualityLevel.high
          ? VideoQualityLevel.standard
          : VideoQualityLevel.low;

  static VideoQualityLevel _stepUp(VideoQualityLevel l) =>
      l == VideoQualityLevel.low
          ? VideoQualityLevel.standard
          : VideoQualityLevel.high;
}
