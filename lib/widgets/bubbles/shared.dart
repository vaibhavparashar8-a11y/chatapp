part of '../message_bubble.dart';

// ── Download helpers ─────────────────────────────────────────────────────────

/// Scratch path for a download, inside the app's own cache.
///
/// This is a staging area, never the destination: the user-visible copy is
/// written by [MediaStoreService.saveToMyTask]. Keeping the temp file lets
/// `OpenFile` hand a real path to the viewer app afterwards.
Future<String> _tempPath(String fileName) async {
  final dir = await getTemporaryDirectory();
  return '${dir.path}/$fileName';
}

/// Downloads [url] and files the result under Download/MyTask as [fileName].
///
/// Returns the temp path the bytes were staged at (for opening), or null if
/// either the download or the export to MyTask failed — a partial success is
/// reported as failure, since a file the user cannot find in MyTask is exactly
/// the bug this replaced.
Future<String?> _downloadToMyTask(
  String url,
  String fileName, {
  void Function(int received, int total)? onProgress,
}) async {
  final temp = await _tempPath(fileName);
  await Dio().download(url, temp, onReceiveProgress: onProgress);
  final saved = await MediaStoreService.saveToMyTask(temp, fileName);
  return saved == null ? null : temp;
}

// ── Message tail ─────────────────────────────────────────────────────────────

class _TailPainter extends CustomPainter {
  final Color color;
  final bool isMe;

  const _TailPainter({required this.color, required this.isMe});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path();
    if (isMe) {
      // Right-pointing tail for sent messages
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
    } else {
      // Left-pointing tail for received messages
      path.moveTo(size.width, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      old.color != color || old.isMe != isMe;
}
