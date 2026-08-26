// test/utils/media_types_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/utils/media_types.dart';

void main() {
  group('extensionOf', () {
    test('reads the extension from a bare name and from a path', () {
      expect(extensionOf('photo.JPG'), 'jpg');
      expect(extensionOf('/storage/emulated/0/DCIM/clip.mp4'), 'mp4');
      expect(extensionOf(r'C:\Users\me\notes.pdf'), 'pdf');
    });

    test('takes the last extension only', () {
      expect(extensionOf('archive.tar.gz'), 'gz');
    });

    test('is empty when there is nothing usable', () {
      expect(extensionOf('README'), '');
      expect(extensionOf('trailing.'), '');
      expect(extensionOf('.gitignore'), ''); // dotfile, not an extension
    });
  });

  group('mediaTypeForPath', () {
    test('classifies photos, including the ones a phone camera produces', () {
      for (final name in ['a.jpg', 'a.JPEG', 'a.png', 'a.webp', 'a.heic']) {
        expect(mediaTypeForPath(name), MessageType.image, reason: name);
      }
    });

    test('classifies videos the gallery can hand back', () {
      for (final name in ['a.mp4', 'a.MOV', 'a.mkv', 'a.3gp', 'a.webm']) {
        expect(mediaTypeForPath(name), MessageType.video, reason: name);
      }
    });

    test('gif stays its own type, not a still image', () {
      expect(mediaTypeForPath('party.gif'), MessageType.gif);
    });

    test('classifies audio', () {
      expect(mediaTypeForPath('song.m4a'), MessageType.audio);
      expect(mediaTypeForPath('voice.OGG'), MessageType.audio);
    });

    test('anything unrecognised sends as a plain file', () {
      expect(mediaTypeForPath('report.pdf'), MessageType.file);
      expect(mediaTypeForPath('no-extension'), MessageType.file);
      expect(mediaTypeForPath('weird.xyz'), MessageType.file);
    });
  });
}
