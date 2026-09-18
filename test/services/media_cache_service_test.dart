import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/services/log_service.dart';
import 'package:chatapp/services/media_cache_service.dart';

void main() {
  late List<String> seededUrls;
  late List<String> seededExtensions;
  late List<int> seededBytes;
  late bool failSeed;
  late Directory tmp;
  late File sample;

  setUp(() {
    LogService.testMode = true;
    seededUrls = [];
    seededExtensions = [];
    seededBytes = [];
    failSeed = false;
    MediaCacheService.testMode = false;
    MediaCacheService.seeder = (url, source, ext) async {
      if (failSeed) throw Exception('disk full');
      seededUrls.add(url);
      seededExtensions.add(ext);
      await for (final chunk in source) {
        seededBytes.addAll(chunk);
      }
    };
    tmp = Directory.systemTemp.createTempSync('media_cache_test');
    sample = File('${tmp.path}/clip.mp4')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() {
    LogService.testMode = false;
    MediaCacheService.testMode = false;
    tmp.deleteSync(recursive: true);
  });

  test('seeds the file under the download URL with its extension', () async {
    await MediaCacheService.seed('https://example.com/a/b.mp4?token=1', sample);

    expect(seededUrls, ['https://example.com/a/b.mp4?token=1']);
    expect(seededExtensions, ['mp4']);
    expect(seededBytes, [1, 2, 3]);
  });

  test('falls back to a generic extension when the file has none', () async {
    final noExt = File('${tmp.path}/blob')..writeAsBytesSync([1]);

    await MediaCacheService.seed('https://example.com/blob', noExt);

    expect(seededExtensions, ['file']);
  });

  test('testMode skips the cache entirely', () async {
    MediaCacheService.testMode = true;

    await MediaCacheService.seed('https://example.com/a.jpg', sample);

    expect(seededUrls, isEmpty);
  });

  // A cache miss only costs a re-download — it must never fail the send.
  test('swallows cache failures', () async {
    failSeed = true;

    await expectLater(
        MediaCacheService.seed('https://example.com/a.jpg', sample), completes);
  });
}
