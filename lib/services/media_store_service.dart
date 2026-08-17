// lib/services/media_store_service.dart

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'log_service.dart';

/// Exports downloaded chat files into one user-visible folder:
/// **Internal storage / Download / MyTask**.
///
/// Everything used to be written to `getExternalStorageDirectory()`, i.e.
/// `Android/data/com.example.chatapp/files/` — technically "saved", but hidden
/// from Files/My Files on modern Android and gone when the app is uninstalled,
/// which is why downloads seemed to vanish. The app targets SDK 36, where a
/// plain write into shared storage is ignored, so the real save happens
/// natively through MediaStore (see `MyTaskStorage.java`).
class MediaStoreService {
  static const _channel = MethodChannel('com.example.chatapp/storage');

  /// The folder name shown to the user. Mirrors `MyTaskStorage.FOLDER`.
  static const folderName = 'MyTask';

  /// No-ops (returns a fake destination) in tests — there is no Android side.
  static bool testMode = false;

  /// Records what [saveToMyTask] was asked to save while [testMode] is on.
  @visibleForTesting
  static final List<String> savedInTestMode = [];

  /// Copies the already-downloaded file at [sourcePath] into Download/MyTask
  /// as [fileName].
  ///
  /// Returns the saved item's identifier (a `content://` URI on API 29+, an
  /// absolute path below that), or null if the export failed — the caller
  /// should tell the user, since a null here means the file is NOT in the
  /// folder they will go looking in.
  static Future<String?> saveToMyTask(
    String sourcePath,
    String fileName, {
    String? mimeType,
  }) async {
    if (testMode) {
      savedInTestMode.add(fileName);
      return 'test://$folderName/$fileName';
    }
    try {
      return await _channel.invokeMethod<String>('saveToMyTask', {
        'path': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType ?? mimeTypeFor(fileName),
      });
    } on PlatformException catch (e) {
      LogService.e('MediaStore', 'saveToMyTask failed for $fileName: ${e.message}');
      return null;
    } catch (e) {
      LogService.e('MediaStore', 'saveToMyTask failed for $fileName: $e');
      return null;
    }
  }

  /// Best-effort MIME type from the file extension. MediaStore uses it to
  /// decide which app can open the file; an unknown type still saves fine.
  @visibleForTesting
  static String? mimeTypeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0) return null;
    switch (fileName.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png':  return 'image/png';
      case 'webp': return 'image/webp';
      case 'gif':  return 'image/gif';
      case 'mp4':  return 'video/mp4';
      case 'mkv':  return 'video/x-matroska';
      case 'mov':  return 'video/quicktime';
      case 'avi':  return 'video/x-msvideo';
      case 'mp3':  return 'audio/mpeg';
      case 'm4a':  return 'audio/mp4';
      case 'aac':  return 'audio/aac';
      case 'wav':  return 'audio/wav';
      case 'ogg':  return 'audio/ogg';
      case 'pdf':  return 'application/pdf';
      case 'txt':  return 'text/plain';
      case 'zip':  return 'application/zip';
      case 'doc':  return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':  return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      default:     return null;
    }
  }
}
