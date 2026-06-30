import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../constants.dart';

class DeviceService {
  static const _roleKey = 'sender_role';
  static const _deviceKey = 'device_id';

  static String deviceId = '';
  static String role = '';

  /// Call once at startup before runApp.
  /// Assigns mySenderId to 'A' or 'B' via Firestore coordination so both
  /// phones can use the same APK without any manual config.
  static Future<void> initSenderId() async {
    final prefs = await SharedPreferences.getInstance();

    // Reuse role from previous launch
    final saved = prefs.getString(_roleKey);
    if (saved == 'A' || saved == 'B') {
      final r = saved!;
      mySenderId = r;
      role = r;
      deviceId = prefs.getString(_deviceKey) ?? 'unknown';
      return;
    }

    // Stable device ID persisted across app launches
    String resolvedDeviceId = prefs.getString(_deviceKey) ?? '';
    if (resolvedDeviceId.isEmpty) {
      resolvedDeviceId = const Uuid().v4();
      await prefs.setString(_deviceKey, resolvedDeviceId);
    }
    deviceId = resolvedDeviceId;

    final roomRef = FirebaseFirestore.instance
        .collection('rooms')
        .doc(chatRoomId);

    final assignedRole = await FirebaseFirestore.instance
        .runTransaction<String>((tx) async {
      final snap = await tx.get(roomRef);
      final data = snap.data() ?? {};
      final assignments =
          Map<String, dynamic>.from(data['roleAssignments'] ?? {});

      // Already registered on a previous install (same device ID)
      if (assignments['A'] == resolvedDeviceId) return 'A';
      if (assignments['B'] == resolvedDeviceId) return 'B';

      final aFree = assignments['A'] == null || assignments['A'] == '';
      final bFree = assignments['B'] == null || assignments['B'] == '';

      if (aFree) {
        // Slot A is free — claim it
        tx.set(roomRef,
            {'roleAssignments': {...assignments, 'A': resolvedDeviceId}},
            SetOptions(merge: true));
        return 'A';
      } else if (bFree) {
        // Slot B is free — claim it
        tx.set(roomRef,
            {'roleAssignments': {...assignments, 'B': resolvedDeviceId}},
            SetOptions(merge: true));
        return 'B';
      } else {
        // Both slots taken by other devices — claim B (preserves A's assignment)
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

  /// Call this from a hidden reset action if you ever need both phones
  /// to re-register (e.g. after reinstalling on both devices).
  static Future<void> resetAssignments() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roleKey);
    await prefs.remove(_deviceKey);
    await FirebaseFirestore.instance
        .collection('rooms')
        .doc(chatRoomId)
        .set({'roleAssignments': {}}, SetOptions(merge: true));
    mySenderId = '';
  }
}
