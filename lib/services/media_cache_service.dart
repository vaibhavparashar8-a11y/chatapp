import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'log_service.dart';

/// Writes [source] into the shared media cache under [url]'s key.
typedef CacheSeeder = Future<void> Function(
    String url, Stream<List<int>> source, String fileExtension);

/// Seeds the shared media cache with files this device already has on disk.
///
/// Every media bubble reads through [DefaultCacheManager] keyed on the
/// download URL — `CachedNetworkImage` for photos, `cachedMediaFile` for
/// videos. Without this, the *sender* re-downloaded the very file it had just
/// uploaded: the optimistic bubble is dropped as soon as the Firestore message
/// arrives, and the real bubble found nothing cached for that URL. On a video
/// that meant seconds of spinner over a clip sitting in local storage. Seeding
/// right after the upload makes the sender's copy appear instantly, for the
/// cost of one file copy.
class MediaCacheService {
  MediaCacheService._();

  /// Set by tests: seeding becomes a no-op, so no cache or disk is touched.
  static bool testMode = false;

  /// Injectable seam — the real one streams into [DefaultCacheManager].
  static CacheSeeder seeder = _putInDefaultCache;

  static Future<void> _putInDefaultCache(
          String url, Stream<List<int>> source, String fileExtension) =>
      DefaultCacheManager()
          .putFileStream(url, source, fileExtension: fileExtension);

  /// Copies [file] into the cache under [url]'s key.
  ///
  /// Streams from disk (never `readAsBytes`) so a 50 MB video does not spike
  /// the Dart heap — the same reason uploads use `putFile`. Best-effort: a
  /// miss only costs a re-download later, so failures are logged, not thrown.
  static Future<void> seed(String url, File file) async {
    if (testMode) return;
    try {
      final name = file.path.split(Platform.pathSeparator).last;
      final ext = name.contains('.') ? name.split('.').last : 'file';
      await seeder(url, file.openRead(), ext);
    } catch (e) {
      LogService.w('MediaCache', 'seed failed for $url: $e');
    }
  }
}
