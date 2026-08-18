// tool/generate_app_icon.dart
//
// Regenerates the launcher icon artwork into assets/. Run with:
//
//   flutter test tool/generate_app_icon.dart
//
// then re-run `dart run flutter_launcher_icons` to push it into android/res.
//
// It is written as a test so it can use Flutter's own renderer — real
// anti-aliasing, real gradients — instead of hand-rolling PNG pixels. Nothing
// here runs in the app.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = 1024.0;

// The app's violet, lit from the top-left exactly like the chat bubbles.
const _light = Color(0xFF9F67FF);
const _mid = Color(0xFF7C3AED);
const _deep = Color(0xFF4C1D95);

/// Android masks the adaptive foreground to roughly the middle 66% of the
/// canvas. At this scale the tick spans about 55% of the width — comfortably
/// inside that, but still large enough not to look shrunken next to other
/// launcher icons (0.62 put it at 38%, which read as a tiny mark on a big tile).
const _foregroundScale = 1.15;

void main() {
  test('generate launcher icon artwork', () async {
    await _write('assets/icon.png', _paintFullIcon);
    await _write('assets/icon_foreground.png', _paintForeground);
    await _write('assets/icon_background.png', _paintBackground);
  });
}

/// Legacy/full icon: rounded-square tile with the check on it.
void _paintFullIcon(Canvas canvas) {
  _paintTile(canvas, rounded: true);
  _paintCheck(canvas, scale: 1.0);
}

/// Adaptive foreground: the check alone on transparency, pulled inside the
/// safe zone so a circular launcher mask cannot clip its arms.
void _paintForeground(Canvas canvas) {
  _paintCheck(canvas, scale: _foregroundScale);
}

/// Adaptive background: full-bleed gradient, no rounding — the launcher
/// applies its own mask (circle, squircle, teardrop…).
void _paintBackground(Canvas canvas) {
  _paintTile(canvas, rounded: false);
}

void _paintTile(Canvas canvas, {required bool rounded}) {
  final rect = const Rect.fromLTWH(0, 0, _size, _size);
  final shape = rounded
      ? RRect.fromRectAndRadius(rect, const Radius.circular(_size * 0.225))
      : RRect.fromRectAndRadius(rect, Radius.zero);

  canvas.drawRRect(
    shape,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_light, _mid, _deep],
        stops: [0.0, 0.55, 1.0],
      ).createShader(rect),
  );

  // Soft highlight in the top-left corner: the same trick that stops the
  // in-app surfaces reading as flat blocks.
  canvas.drawRRect(
    shape,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.6, -0.7),
        radius: 1.1,
        colors: [Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0.0)],
      ).createShader(rect),
  );
}

/// The check mark, centred, drawn as a stroked path with rounded caps so it
/// stays crisp when the launcher scales it down.
void _paintCheck(Canvas canvas, {required double scale}) {
  const c = _size / 2;
  final s = _size * scale;

  // Proportions of the tick within its own box.
  final path = Path()
    ..moveTo(c - s * 0.235, c + s * 0.020)
    ..lineTo(c - s * 0.070, c + s * 0.185)
    ..lineTo(c + s * 0.245, c - s * 0.180);

  // Faint shadow under the stroke gives the mark a little lift off the tile.
  canvas.drawPath(
    path.shift(const Offset(0, 10)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.115
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.black.withValues(alpha: 0.16)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
  );

  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.115
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white,
  );
}

Future<void> _write(String path, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder,
      const Rect.fromLTWH(0, 0, _size, _size));
  paint(canvas);
  final image =
      await recorder.endRecording().toImage(_size.toInt(), _size.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path);
  await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
  // ignore: avoid_print
  print('wrote $path (${await file.length()} bytes)');
}
