part of '../message_bubble.dart';

// ── Save-path helper ─────────────────────────────────────────────────────────

Future<String> _savePath(String fileName) async {
  // App-specific external storage — writable on all Android versions, no extra
  // permission needed. Accessible via file manager under
  // Android/data/com.example.chatapp/files/
  final dir = await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();
  return '${dir.path}/$fileName';
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
