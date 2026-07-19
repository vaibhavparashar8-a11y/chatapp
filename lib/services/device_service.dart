import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';
import 'chat_service.dart';
import 'log_service.dart';

class DeviceService {
  /// Skips Firestore access in widget tests (heartbeat + last-opened stream).
  static bool testMode = false;

  static const _roleKey = 'sender_role';
  static const _deviceKey = 'device_id';

  static String deviceId = '';
  static String role = '';

  /// Call once at startup before runApp.
  /// Assigns mySenderId to 'A' or 'B' via Firestore coordination so both
  /// phones can use the same APK without any manual config.
  static Future<void> initSenderId() async {
    final prefs = await SharedPreferences.getInstance();

    // Fast path: reuse cached role from a previous launch.
    // Even if SharedPreferences is wiped on reinstall, we fall through to the
    // Firestore transaction which will re-recognise the device via its stable ID.
    final saved = prefs.getString(_roleKey);
    if (saved == 'A' || saved == 'B') {
      final r = saved!;
      mySenderId = r;
      role = r;
      deviceId = prefs.getString(_deviceKey) ?? 'unknown';
      return;
    }

    // Get a stable device identifier that survives app reinstall.
    final resolvedDeviceId = await _getStableDeviceId(prefs);
    deviceId = resolvedDeviceId;

    final roomRef =
        FirebaseFirestore.instance.collection('rooms').doc(chatRoomId);

    final assignedRole =
        await FirebaseFirestore.instance.runTransaction<String>((tx) async {
      final snap = await tx.get(roomRef);
      final data = snap.data() ?? {};
      final assignments =
          Map<String, dynamic>.from(data['roleAssignments'] ?? {});

      // Already registered (same device ID found in either slot) — reclaim role.
      if (assignments['A'] == resolvedDeviceId) return 'A';
      if (assignments['B'] == resolvedDeviceId) return 'B';

      final aFree = assignments['A'] == null || assignments['A'] == '';
      final bFree = assignments['B'] == null || assignments['B'] == '';

      if (aFree) {
        tx.set(roomRef,
            {'roleAssignments': {...assignments, 'A': resolvedDeviceId}},
            SetOptions(merge: true));
        return 'A';
      } else if (bFree) {
        tx.set(roomRef,
            {'roleAssignments': {...assignments, 'B': resolvedDeviceId}},
            SetOptions(merge: true));
        return 'B';
      } else {
        // Both slots taken — this is the "true third device / clean reinstall"
        // path. Claim B (preserves A's assignment).
        tx.set(roomRef,
            {'roleAssignments': {...assignments, 'B': resolvedDeviceId}},
            SetOptions(merge: true));
        return 'B';
      }
    });

    mySenderId = assignedRole;
    role = assignedRole;
    await prefs.setString(_roleKey, assignedRole);
  }

  /// Returns a device identifier that is stable across app reinstalls.
  ///
  /// Uses Android's ANDROID_ID (Settings.Secure.ANDROID_ID) as the primary
  /// source — it is unique per device per signing key and survives reinstall
  /// (resets only on factory reset).  Falls back to a UUID stored in
  /// SharedPreferences for emulators or unusual OEM builds where ANDROID_ID
  /// is unavailable or empty.
  static Future<String> _getStableDeviceId(SharedPreferences prefs) async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.id.isNotEmpty) return info.id;
    } catch (e) {
      LogService.w('DeviceService', 'ANDROID_ID unavailable — falling back to UUID: $e');
    }

    // Fallback: UUID persisted in SharedPreferences.
    String id = prefs.getString(_deviceKey) ?? '';
    if (id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_deviceKey, id);
    }
    return id;
  }

  /// Writes the current timestamp to Firestore so the other device can tell
  /// when this phone last entered the chat screen. Call from ChatScreen.initState().
  static Future<void> writeHeartbeat() async {
    if (testMode) return;
    await _writeHeartbeat(role);
  }

  static Future<void> _writeHeartbeat(String r) async {
    await _writeOpened('appLastOpened', r);
  }

  /// Counts calls to [writeTodoOpened] (incl. in testMode) so widget tests can
  /// assert the todo app records its open time. Unused in production.
  @visibleForTesting
  static int debugTodoOpenedWrites = 0;

  /// Writes the current timestamp so the other device can tell when this phone
  /// last opened the todo app. Call from TodoScreen open / resume. Mirrors
  /// [writeHeartbeat] but under a separate `todoLastOpened` field.
  static Future<void> writeTodoOpened() async {
    debugTodoOpenedWrites++;
    if (testMode) return;
    await _writeOpened('todoLastOpened', role);
  }

  /// Merge `<field>.<role> = serverTimestamp()` onto the room doc.
  static Future<void> _writeOpened(String field, String r) async {
    try {
      await FirebaseFirestore.instance
          .collection('rooms')
          .doc(chatRoomId)
          .set({
        field: {r: FieldValue.serverTimestamp()},
      }, SetOptions(merge: true));
    } catch (e) {
      LogService.e('DeviceService', '$field write failed: $e');
    }
  }

  /// Stream of the timestamp when the *other* device last opened the app.
  /// Emits null if the field has never been written.
  static Stream<DateTime?> otherLastOpenedStream(String otherId) {
    if (testMode) return Stream<DateTime?>.value(null);
    return ChatService.roomDataStream.map((data) {
      final ts = (data['appLastOpened'] as Map<String, dynamic>? ?? {})[otherId];
      if (ts is Timestamp) return ts.toDate();
      return null;
    });
  }

  /// Wipe local role cache and clear Firestore roleAssignments so both devices
  /// must re-register from scratch. Call this if roles get mixed up after
  /// reinstalling on both devices simultaneously.
  static Future<void> resetAssignments() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roleKey);
    await prefs.remove(_deviceKey);
    await FirebaseFirestore.instance
        .collection('rooms')
        .doc(chatRoomId)
        .set({'roleAssignments': {}}, SetOptions(merge: true));
    mySenderId = '';
    role = '';
    deviceId = '';
  }
}
