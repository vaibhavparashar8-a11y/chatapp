import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/captured_media.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/screens/media_preview_screen.dart';
import 'package:chatapp/services/log_service.dart';

/// Review-before-send. The screen's whole job is to answer one question —
/// send this, or go back and shoot again — so every test reads what it popped.
/// Pumps past the route transition without `pumpAndSettle`: while a clip is
/// still opening the screen shows an indeterminate spinner, and that animation
/// never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory tmp;
  late File photo;

  // 1×1 transparent PNG, enough for Image.file to decode.
  final png = Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10,
    73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180,
    0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]);

  setUp(() {
    LogService.testMode = true;
    tmp = Directory.systemTemp.createTempSync('preview_test');
    photo = File('${tmp.path}/shot.jpg')..writeAsBytesSync(png);
  });

  tearDown(() {
    LogService.testMode = false;
    tmp.deleteSync(recursive: true);
  });

  /// Pumps the preview behind a button and returns what it popped.
  Future<bool?> openPreview(WidgetTester tester, CapturedMedia media) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                    builder: (_) => MediaPreviewScreen(media: media)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);
    return result;
  }

  testWidgets('shows the captured photo with both choices', (tester) async {
    await openPreview(tester, CapturedMedia(photo, MessageType.image));

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Retake'), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });

  testWidgets('the send button confirms', (tester) async {
    bool? sent;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              sent = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => MediaPreviewScreen(
                      media: CapturedMedia(photo, MessageType.image)),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.send_rounded));
    await _settle(tester);

    expect(sent, isTrue);
  });

  testWidgets('Retake discards', (tester) async {
    bool? sent;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              sent = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => MediaPreviewScreen(
                      media: CapturedMedia(photo, MessageType.image)),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);

    await tester.tap(find.text('Retake'));
    await _settle(tester);

    // Not null and not true: the caller must be able to tell "go back and
    // shoot again" apart from "send it".
    expect(sent, isFalse);
  });

  testWidgets('the back arrow discards too', (tester) async {
    await openPreview(tester, CapturedMedia(photo, MessageType.image));

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await _settle(tester);

    expect(find.byType(MediaPreviewScreen), findsNothing);
  });

  // The video plugin cannot initialise in a widget test, which is the same
  // shape as a codec the phone cannot decode: the clip is still on disk and
  // must stay sendable.
  testWidgets('a clip that cannot be previewed can still be sent',
      (tester) async {
    final clip = File('${tmp.path}/clip.mp4')..writeAsBytesSync([0, 1, 2]);

    await openPreview(tester, CapturedMedia(clip, MessageType.video));

    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });
}
