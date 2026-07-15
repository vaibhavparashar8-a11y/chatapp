import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/services/whatsapp_settings_service.dart';

void main() {
  group('WhatsAppSettings', () {
    test('defaults are off, 6:30, empty phone, current offset', () {
      final s = WhatsAppSettings.defaults();
      expect(s.enabled, false);
      expect(s.hour, 6);
      expect(s.minute, 30);
      expect(s.phone, '');
      expect(s.utcOffsetMinutes, DateTime.now().timeZoneOffset.inMinutes);
    });

    test('toMap/fromMap round-trips every field', () {
      const s = WhatsAppSettings(
        enabled: true,
        hour: 8,
        minute: 15,
        utcOffsetMinutes: 330,
        phone: '919812345678',
      );
      final back = WhatsAppSettings.fromMap(s.toMap());
      expect(back.enabled, true);
      expect(back.hour, 8);
      expect(back.minute, 15);
      expect(back.utcOffsetMinutes, 330);
      expect(back.phone, '919812345678');
    });

    test('fromMap tolerates missing keys with safe defaults', () {
      final s = WhatsAppSettings.fromMap(const {});
      expect(s.enabled, false);
      expect(s.hour, 6);
      expect(s.minute, 30);
      expect(s.phone, '');
    });

    test('fromMap coerces numeric hour/minute stored as num', () {
      final s = WhatsAppSettings.fromMap(const {
        'enabled': true,
        'hour': 22.0,
        'minute': 5.0,
        'utcOffsetMinutes': 330.0,
        'phone': '111',
      });
      expect(s.hour, 22);
      expect(s.minute, 5);
      expect(s.utcOffsetMinutes, 330);
    });

    test('copyWith overrides only the given fields', () {
      const s = WhatsAppSettings(
        enabled: false,
        hour: 6,
        minute: 30,
        utcOffsetMinutes: 0,
        phone: '',
      );
      final s2 = s.copyWith(enabled: true, hour: 9, phone: '123');
      expect(s2.enabled, true);
      expect(s2.hour, 9);
      expect(s2.minute, 30); // unchanged
      expect(s2.phone, '123');
      expect(s2.utcOffsetMinutes, 0); // unchanged
    });
  });

  group('WhatsAppSettingsService test mode', () {
    setUp(() => WhatsAppSettingsService.testMode = true);
    tearDown(() => WhatsAppSettingsService.testMode = false);

    test('load returns defaults and save is a no-op in test mode', () async {
      final s = await WhatsAppSettingsService.load();
      expect(s.enabled, false);
      // save must not throw without Firebase initialised
      await WhatsAppSettingsService.save(s.copyWith(enabled: true));
    });
  });
}
