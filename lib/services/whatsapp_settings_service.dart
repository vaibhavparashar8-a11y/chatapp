import 'package:cloud_firestore/cloud_firestore.dart';
import '../constants.dart';

/// Per-device WhatsApp reminder preferences.
///
/// Each phone owns ONE settings doc keyed by its role:
/// `rooms/{chatRoomId}/settings/whatsapp_{role}`. The device writes its own
/// role's doc; the two Cloud Functions (`sendWhatsappPings`,
/// `sendWhatsappDigest`) read both roles' docs to decide who to message.
///
/// The digest time is stored as a wall-clock [hour]/[minute] plus the device's
/// [utcOffsetMinutes], so the function can compute "is it that person's local
/// time now?" without a timezone database. India has no DST, so a captured
/// offset stays valid. The CallMeBot API key is NOT stored here — it lives in
/// Secret Manager server-side. Only the destination [phone] is stored.
class WhatsAppSettings {
  final bool enabled;
  final int hour; // 0–23, local wall clock
  final int minute; // 0–59
  final int utcOffsetMinutes; // device offset from UTC when saved
  final String phone; // destination number, country code, digits only, no '+'

  const WhatsAppSettings({
    required this.enabled,
    required this.hour,
    required this.minute,
    required this.utcOffsetMinutes,
    required this.phone,
  });

  /// Sensible defaults for a fresh device: off, 6:30 AM, current offset.
  factory WhatsAppSettings.defaults() => WhatsAppSettings(
        enabled: false,
        hour: 6,
        minute: 30,
        utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
        phone: '',
      );

  WhatsAppSettings copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    int? utcOffsetMinutes,
    String? phone,
  }) =>
      WhatsAppSettings(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        utcOffsetMinutes: utcOffsetMinutes ?? this.utcOffsetMinutes,
        phone: phone ?? this.phone,
      );

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'hour': hour,
        'minute': minute,
        'utcOffsetMinutes': utcOffsetMinutes,
        'phone': phone,
      };

  static WhatsAppSettings fromMap(Map<String, dynamic> m) => WhatsAppSettings(
        enabled: m['enabled'] as bool? ?? false,
        hour: (m['hour'] as num?)?.toInt() ?? 6,
        minute: (m['minute'] as num?)?.toInt() ?? 30,
        utcOffsetMinutes: (m['utcOffsetMinutes'] as num?)?.toInt() ??
            DateTime.now().timeZoneOffset.inMinutes,
        phone: (m['phone'] as String?) ?? '',
      );
}

class WhatsAppSettingsService {
  static bool testMode = false;

  static final _db = FirebaseFirestore.instance;

  static DocumentReference _doc(String role) => _db
      .collection('rooms')
      .doc(chatRoomId)
      .collection('settings')
      .doc('whatsapp_$role');

  /// Load this device's saved settings, or defaults if none exist yet.
  static Future<WhatsAppSettings> load() async {
    if (testMode) return WhatsAppSettings.defaults();
    final snap = await _doc(mySenderId).get();
    final data = snap.data() as Map<String, dynamic>?;
    if (data == null) return WhatsAppSettings.defaults();
    return WhatsAppSettings.fromMap(data);
  }

  /// Persist this device's settings. Always re-stamps [utcOffsetMinutes] from
  /// the current device offset so a moved/changed timezone is reflected.
  static Future<void> save(WhatsAppSettings settings) async {
    if (testMode) return;
    final withOffset = settings.copyWith(
      utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
    );
    await _doc(mySenderId).set(withOffset.toMap(), SetOptions(merge: true));
  }
}
