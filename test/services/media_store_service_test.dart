import 'package:chatapp/services/media_store_service.dart';
import 'package:chatapp/services/log_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LogService.testMode = true);
  tearDownAll(() => LogService.testMode = false);

  group('mimeTypeFor', () {
    test('maps the media types the chat can send', () {
      expect(MediaStoreService.mimeTypeFor('cat.jpg'), 'image/jpeg');
      expect(MediaStoreService.mimeTypeFor('cat.PNG'), 'image/png');
      expect(MediaStoreService.mimeTypeFor('loop.gif'), 'image/gif');
      expect(MediaStoreService.mimeTypeFor('clip.mp4'), 'video/mp4');
      expect(MediaStoreService.mimeTypeFor('voice.m4a'), 'audio/mp4');
      expect(MediaStoreService.mimeTypeFor('notes.pdf'), 'application/pdf');
    });

    test('unknown or extensionless names save without a type', () {
      expect(MediaStoreService.mimeTypeFor('mystery.qqq'), isNull);
      expect(MediaStoreService.mimeTypeFor('README'), isNull);
    });

    // "photo.tar.gz" must not be read as ".tar.gz"; only the last segment counts.
    test('uses the last extension only', () {
      expect(MediaStoreService.mimeTypeFor('archive.tar.zip'), 'application/zip');
    });
  });

  group('saveToMyTask', () {
    const channel = MethodChannel('com.example.chatapp/storage');
    late List<MethodCall> calls;

    void mockNative({Object? Function()? respond}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return respond?.call();
      });
    }

    setUp(() => calls = []);
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      MediaStoreService.testMode = false;
      MediaStoreService.savedInTestMode.clear();
    });

    test('passes the path, name and derived mime type to the platform',
        () async {
      mockNative(respond: () => 'content://media/external/downloads/42');

      final result =
          await MediaStoreService.saveToMyTask('/cache/cat.jpg', 'cat.jpg');

      expect(result, 'content://media/external/downloads/42');
      expect(calls.single.method, 'saveToMyTask');
      expect(calls.single.arguments, {
        'path': '/cache/cat.jpg',
        'fileName': 'cat.jpg',
        'mimeType': 'image/jpeg',
      });
    });

    test('an explicit mimeType wins over the guess', () async {
      mockNative(respond: () => 'content://x');
      await MediaStoreService.saveToMyTask('/cache/f.bin', 'f.bin',
          mimeType: 'application/octet-stream');
      expect((calls.single.arguments as Map)['mimeType'],
          'application/octet-stream');
    });

    // Returning null (rather than throwing) is what lets the callers tell the
    // user the file is NOT in the folder they will go looking in.
    test('a platform failure reports null instead of throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'save_failed', message: 'no space');
      });

      expect(await MediaStoreService.saveToMyTask('/cache/a.mp4', 'a.mp4'),
          isNull);
    });

    test('testMode records the save and never touches the platform', () async {
      mockNative(respond: () => 'content://never');
      MediaStoreService.testMode = true;

      final result =
          await MediaStoreService.saveToMyTask('/cache/cat.jpg', 'cat.jpg');

      expect(result, contains('cat.jpg'));
      expect(MediaStoreService.savedInTestMode, ['cat.jpg']);
      expect(calls, isEmpty);
    });
  });
}
