import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../models/gallery_item.dart';
import 'log_service.dart';

/// Reads the device gallery for the camera screen's recent-media strip.
///
/// The only file that imports `photo_manager`: everything above it works in
/// [GalleryItem]s, so the strip and its tests never touch the platform.
class MediaLibraryService {
  MediaLibraryService._();

  /// Set by tests: [recent] and [fileFor] answer from [testItems] / [testFiles]
  /// instead of the platform.
  static bool testMode = false;
  static List<GalleryItem> testItems = const [];
  static Map<String, File> testFiles = const {};

  /// Newest [limit] photos and videos, or an empty list when the user has not
  /// granted gallery access — the strip simply does not appear, the rest of the
  /// camera keeps working.
  static Future<List<GalleryItem>> recent({int limit = 30}) async {
    if (testMode) return testItems;
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        LogService.w('MediaLibrary', 'gallery access denied — strip hidden');
        return const [];
      }
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.common, // images + videos, the two we can send
      );
      if (albums.isEmpty) return const [];
      final assets = await albums.first.getAssetListPaged(page: 0, size: limit);
      return Future.wait(assets.map(_toItem));
    } catch (e) {
      LogService.e('MediaLibrary', 'recent() failed: $e');
      return const [];
    }
  }

  static Future<GalleryItem> _toItem(AssetEntity asset) async {
    // 256 px square: the tiles are ~80 px, and a thumbnail is far cheaper to
    // decode than the original — a strip of full-size photos would stall the
    // camera preview.
    final thumb =
        await asset.thumbnailDataWithSize(const ThumbnailSize.square(256));
    return GalleryItem(
      id: asset.id,
      isVideo: asset.type == AssetType.video,
      thumbnail: thumb,
      duration: Duration(seconds: asset.duration),
    );
  }

  /// The real file behind [id], or null when it cannot be materialised (an
  /// iCloud/cloud-only asset, or a revoked permission).
  static Future<File?> fileFor(String id) async {
    if (testMode) return testFiles[id];
    try {
      final asset = await AssetEntity.fromId(id);
      if (asset == null) {
        LogService.w('MediaLibrary', 'asset $id disappeared');
        return null;
      }
      return asset.file;
    } catch (e) {
      LogService.e('MediaLibrary', 'fileFor($id) failed: $e');
      return null;
    }
  }
}
