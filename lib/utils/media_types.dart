// lib/utils/media_types.dart
//
// Maps a file name/path to the [MessageType] it should be sent as. Pure, so
// the extension lists are unit-testable and live in exactly one place — the
// combined gallery picker and the document picker both classify with it.

import '../models/message.dart';

const _imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'heic', 'heif'};
const _videoExtensions = {'mp4', 'mkv', 'mov', 'avi', 'webm', '3gp', 'm4v'};
const _audioExtensions = {'mp3', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'flac'};

/// Lower-case extension of [path], without the dot. Empty when there is none.
String extensionOf(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Which kind of message [path] should be sent as. Anything unrecognised is a
/// plain file — never guessed at, so an odd extension still sends rather than
/// arriving as a picture that cannot be decoded.
MessageType mediaTypeForPath(String path) {
  final ext = extensionOf(path);
  if (ext == 'gif') return MessageType.gif;
  if (_imageExtensions.contains(ext)) return MessageType.image;
  if (_videoExtensions.contains(ext)) return MessageType.video;
  if (_audioExtensions.contains(ext)) return MessageType.audio;
  return MessageType.file;
}
