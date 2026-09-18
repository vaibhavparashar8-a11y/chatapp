import 'dart:io';

import 'message.dart';

/// What the camera screen hands back: a file on disk plus what kind of message
/// it should become. A list, because the recent strip can return several.
class CapturedMedia {
  final File file;
  final MessageType type;

  const CapturedMedia(this.file, this.type);
}
