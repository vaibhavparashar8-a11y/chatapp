import 'dart:io';
import 'dart:typed_data';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:chatapp/models/captured_media.dart';
import 'package:chatapp/models/gallery_item.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/screens/camera_screen.dart';
import 'package:chatapp/screens/media_preview_screen.dart';
import 'package:chatapp/services/log_service.dart';
import 'package:chatapp/services/media_library_service.dart';
import 'package:chatapp/services/permission_service.dart';
import 'package:chatapp/widgets/camera/camera_mode_switch.dart';
import 'package:chatapp/widgets/camera/recent_media_strip.dart';

/// The real camera plugin never answers in a widget test — the platform
/// channel has nothing on the other end, so the screen would sit on its
/// spinner forever. These tests install a fake [CameraPlatform] instead, which
/// also lets both "no camera" paths be driven deliberately. Everything around
/// the preview (chrome, mode switch, gallery strip) is the live code.
class _FakeCameraPlatform extends CameraPlatform with MockPlatformInterfaceMixin {
  _FakeCameraPlatform({this.throwOnList = false});

  final bool throwOnList;

  @override
  Future<List<CameraDescription>> availableCameras() async {
    if (throwOnList) throw CameraException('error', 'no camera service');
    return const [];
  }
}
/// Pumps past the route transition and the pending async work without
/// `pumpAndSettle`: while there is no preview the screen shows an
/// indeterminate spinner, and that animation never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // 1×1 transparent PNG, enough for Image.memory.
  final png = Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10,
    73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180,
    0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]);

  setUp(() {
    LogService.testMode = true;
    MediaLibraryService.testMode = true;
    MediaLibraryService.testItems = const [];
    MediaLibraryService.testFiles = const {};
    PermissionService.testMode = true;
    PermissionService.testGranted = true;
    CameraPlatform.instance = _FakeCameraPlatform();
  });

  tearDown(() {
    LogService.testMode = false;
    MediaLibraryService.testMode = false;
    MediaLibraryService.testItems = const [];
    MediaLibraryService.testFiles = const {};
    PermissionService.testMode = false;
    PermissionService.testGranted = true;
  });

  /// Pumps the camera behind a button, so a test can read what it popped.
  Future<List<CapturedMedia>?> openCamera(WidgetTester tester) async {
    List<CapturedMedia>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<List<CapturedMedia>>(
                MaterialPageRoute(builder: (_) => const CameraScreen()),
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

  testWidgets('explains itself instead of showing a black rectangle when the '
      'camera is unavailable', (tester) async {
    CameraPlatform.instance = _FakeCameraPlatform(throwOnList: true);

    await openCamera(tester);

    expect(find.text('Camera unavailable'), findsOneWidget);
    // The chrome stays usable — closing must never depend on the preview.
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('says so when the device reports no camera at all',
      (tester) async {
    await openCamera(tester);

    expect(find.text('No camera on this device'), findsOneWidget);
  });

  testWidgets('says so when the camera permission is refused', (tester) async {
    PermissionService.testGranted = false;

    await openCamera(tester);

    expect(find.text('Camera permission is needed'), findsOneWidget);
  });

  testWidgets('offers both capture modes with PHOTO selected first',
      (tester) async {
    await openCamera(tester);

    expect(find.text('PHOTO'), findsOneWidget);
    expect(find.text('VIDEO'), findsOneWidget);
    expect(tester.widget<CameraModeSwitch>(find.byType(CameraModeSwitch))
        .videoMode, isFalse);

    await tester.tap(find.text('VIDEO'));
    await tester.pump();
    expect(tester.widget<CameraModeSwitch>(find.byType(CameraModeSwitch))
        .videoMode, isTrue);
  });

  testWidgets('shows the recent gallery items', (tester) async {
    MediaLibraryService.testItems = [
      GalleryItem(id: 'a', isVideo: false, thumbnail: png),
      GalleryItem(id: 'b', isVideo: true, thumbnail: png),
    ];

    await openCamera(tester);

    expect(tester.widget<RecentMediaStrip>(find.byType(RecentMediaStrip))
        .items.length, 2);
  });

  testWidgets('tapping a strip video pops it as a video message',
      (tester) async {
    final file = File('/pics/clip.mp4');
    MediaLibraryService.testItems = [
      GalleryItem(id: 'b', isVideo: true, thumbnail: png),
    ];
    MediaLibraryService.testFiles = {'b': file};

    List<CapturedMedia>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<List<CapturedMedia>>(
                MaterialPageRoute(builder: (_) => const CameraScreen()),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);

    await tester.tap(find.byType(Image).first);
    await _settle(tester);

    // Nothing is sent until the preview is confirmed.
    expect(find.byType(MediaPreviewScreen), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.byIcon(Icons.send_rounded));
    await _settle(tester);

    expect(result, isNotNull);
    expect(result!.single.file.path, file.path);
    // The strip carries photos and videos; the type must follow the asset, not
    // the selected capture mode.
    expect(result!.single.type, MessageType.video);
  });

  testWidgets('declining the preview returns to the viewfinder, sending nothing',
      (tester) async {
    final file = File('/pics/shot.jpg');
    MediaLibraryService.testItems = [
      GalleryItem(id: 'a', isVideo: false, thumbnail: png),
    ];
    MediaLibraryService.testFiles = {'a': file};

    List<CapturedMedia>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<List<CapturedMedia>>(
                MaterialPageRoute(builder: (_) => const CameraScreen()),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await _settle(tester);

    await tester.tap(find.byType(Image).first);
    await _settle(tester);
    await tester.tap(find.text('Retake'));
    await _settle(tester);

    // Back on the camera, not back in the chat.
    expect(find.byType(CameraScreen), findsOneWidget);
    expect(find.byType(MediaPreviewScreen), findsNothing);
    expect(result, isNull);
  });

  testWidgets('a strip item whose file cannot be resolved reports instead of '
      'sending', (tester) async {
    MediaLibraryService.testItems = [
      GalleryItem(id: 'gone', isVideo: false, thumbnail: png),
    ];

    await openCamera(tester);
    await tester.tap(find.byType(Image).first);
    await _settle(tester);

    expect(find.text('That file is not available on this phone'),
        findsOneWidget);
    expect(find.byType(CameraScreen), findsOneWidget); // still open
  });
}
