import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/gallery_item.dart';
import 'package:chatapp/theme/chat_theme.dart';
import 'package:chatapp/widgets/camera/camera_mode_switch.dart';
import 'package:chatapp/widgets/camera/capture_button.dart';
import 'package:chatapp/widgets/camera/recent_media_strip.dart';

/// The three presentational pieces of the in-app camera. They take plain data
/// and callbacks precisely so they can be driven without the camera plugin.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: child))),
      );

  group('CaptureButton', () {
    testWidgets('reports tap and hold separately', (tester) async {
      final events = <String>[];
      await pump(
        tester,
        CaptureButton(
          recording: false,
          onTap: () => events.add('tap'),
          onHoldStart: () => events.add('hold-start'),
          onHoldEnd: () => events.add('hold-end'),
        ),
      );

      await tester.tap(find.byType(CaptureButton));
      await tester.pump();
      expect(events, ['tap']);

      await tester.longPress(find.byType(CaptureButton));
      await tester.pump();
      // A press-and-hold must not also count as a tap, or a held recording
      // would fire the photo shutter as well.
      expect(events, ['tap', 'hold-start', 'hold-end']);
    });

    testWidgets('turns into a red stop square while recording',
        (tester) async {
      await pump(
        tester,
        CaptureButton(
          recording: true,
          onTap: () {},
          onHoldStart: () {},
          onHoldEnd: () {},
        ),
      );
      await tester.pumpAndSettle();

      final core = tester.widgetList<AnimatedContainer>(
          find.byType(AnimatedContainer, skipOffstage: false));
      final decorations =
          core.map((c) => c.decoration).whereType<BoxDecoration>();
      expect(decorations.any((d) => d.color == ChatTheme.danger), isTrue);
      expect(decorations.any((d) => d.shape == BoxShape.rectangle), isTrue);
    });
  });

  group('CameraModeSwitch', () {
    testWidgets('accents the active mode and reports the other', (tester) async {
      bool? chosen;
      await pump(
        tester,
        CameraModeSwitch(videoMode: false, onChanged: (v) => chosen = v),
      );

      Color? colorOf(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;
      expect(colorOf('PHOTO'), ChatTheme.accent);
      expect(colorOf('VIDEO'), isNot(ChatTheme.accent));

      await tester.tap(find.text('VIDEO'));
      expect(chosen, isTrue);
    });
  });

  group('RecentMediaStrip', () {
    // 1×1 transparent PNG — enough for Image.memory to decode.
    final png = Uint8List.fromList([
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10,
      73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180,
      0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ]);

    testWidgets('renders nothing when the gallery is empty', (tester) async {
      await pump(tester, RecentMediaStrip(items: const [], onTap: (_) {}));

      // An empty grey band would read as a broken strip; it must collapse.
      expect(find.byType(Image), findsNothing);
      expect(tester.getSize(find.byType(RecentMediaStrip)), Size.zero);
    });

    testWidgets('shows a duration badge on videos only', (tester) async {
      await pump(
        tester,
        RecentMediaStrip(
          items: [
            GalleryItem(id: 'a', isVideo: false, thumbnail: png),
            GalleryItem(
                id: 'b',
                isVideo: true,
                thumbnail: png,
                duration: const Duration(seconds: 75)),
          ],
          onTap: (_) {},
        ),
      );

      expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
      expect(find.text('1:15'), findsOneWidget);
    });

    testWidgets('reports the tapped item', (tester) async {
      GalleryItem? tapped;
      await pump(
        tester,
        RecentMediaStrip(
          items: [GalleryItem(id: 'a', isVideo: false, thumbnail: png)],
          onTap: (item) => tapped = item,
        ),
      );

      await tester.tap(find.byType(Image).first);
      expect(tapped?.id, 'a');
    });
  });
}
