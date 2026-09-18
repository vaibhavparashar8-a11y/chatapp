import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/gallery_item.dart';
import 'package:chatapp/services/media_library_service.dart';

void main() {
  tearDown(() {
    MediaLibraryService.testMode = false;
    MediaLibraryService.testItems = const [];
    MediaLibraryService.testFiles = const {};
  });

  test('testMode answers from the injected gallery', () async {
    MediaLibraryService.testMode = true;
    MediaLibraryService.testItems = const [
      GalleryItem(id: 'a', isVideo: false),
      GalleryItem(id: 'b', isVideo: true),
    ];

    final items = await MediaLibraryService.recent();

    expect(items.map((i) => i.id), ['a', 'b']);
    expect(items.last.isVideo, isTrue);
  });

  test('fileFor resolves an injected asset and null for an unknown one',
      () async {
    final file = File('/pics/a.jpg');
    MediaLibraryService.testMode = true;
    MediaLibraryService.testFiles = {'a': file};

    expect(await MediaLibraryService.fileFor('a'), file);
    // A cloud-only or deleted asset resolves to null — the camera screen must
    // say so rather than send a file that is not there.
    expect(await MediaLibraryService.fileFor('gone'), isNull);
  });
}
