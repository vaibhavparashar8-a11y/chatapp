import 'dart:typed_data';

/// One entry of the device gallery, as the camera screen's recent strip needs
/// it: enough to draw a tile, and an [id] to resolve the real file with when
/// the user actually picks it.
///
/// Plain data — the `photo_manager` types stay inside
/// `services/media_library_service.dart`.
class GalleryItem {
  /// Stable asset id, resolved back to a file by `MediaLibraryService.fileFor`.
  final String id;

  final bool isVideo;

  /// Decoded thumbnail bytes, null when the platform could not produce one.
  final Uint8List? thumbnail;

  /// Clip length, only meaningful when [isVideo].
  final Duration duration;

  const GalleryItem({
    required this.id,
    required this.isVideo,
    this.thumbnail,
    this.duration = Duration.zero,
  });
}
