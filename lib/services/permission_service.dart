import 'package:permission_handler/permission_handler.dart';

import 'log_service.dart';

/// Runtime permission requests, behind a seam.
///
/// `permission_handler` talks to a platform channel that never answers in a
/// widget test, so a screen awaiting it directly just hangs — which is how the
/// camera screen's "permission denied" path used to be untestable.
class PermissionService {
  PermissionService._();

  /// Set by tests: requests answer with [testGranted] instead of the platform.
  static bool testMode = false;
  static bool testGranted = true;

  static Future<bool> requestCamera() => _request(Permission.camera, 'camera');

  static Future<bool> requestMicrophone() =>
      _request(Permission.microphone, 'microphone');

  static Future<bool> _request(Permission permission, String label) async {
    if (testMode) return testGranted;
    try {
      final status = await permission.request();
      if (!status.isGranted) {
        LogService.w('Permission', '$label denied (${status.name})');
      }
      return status.isGranted;
    } catch (e) {
      LogService.e('Permission', '$label request failed: $e');
      return false;
    }
  }
}
