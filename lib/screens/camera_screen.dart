import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/captured_media.dart';
import '../models/gallery_item.dart';
import '../models/message.dart';
import '../services/log_service.dart';
import '../services/media_library_service.dart';
import '../services/permission_service.dart';
import '../theme/chat_theme.dart';
import '../utils/media_types.dart';
import '../utils/time_utils.dart';
import 'media_preview_screen.dart';
import '../widgets/camera/camera_mode_switch.dart';
import '../widgets/camera/capture_button.dart';
import '../widgets/camera/recent_media_strip.dart';

part 'camera/camera_chrome.dart';

/// Full-screen in-app camera, the WhatsApp shape: live preview, PHOTO/VIDEO
/// modes, a shutter that also records on a long press, and a strip of recent
/// gallery items that can be sent without leaving the screen.
///
/// It replaces the two system camera intents (`pickImage`/`pickVideo`), which
/// left the app, looked like the OEM camera, and could not switch between a
/// photo and a clip without backing out first.
///
/// Pops a `List<CapturedMedia>` — null when the user backs out.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;

  bool _videoMode = false;
  bool _recording = false;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;

  /// Set when the camera cannot be used at all (denied permission, no camera,
  /// plugin missing) — the screen then explains itself instead of showing a
  /// black rectangle.
  String? _error;

  Timer? _recordTimer;
  Duration _elapsed = Duration.zero;

  List<GalleryItem> _recent = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_setUpCamera());
    unawaited(_loadRecent());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// The camera holds a hardware resource Android takes back when the app goes
  /// to the background — without this the preview returns frozen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (state == AppLifecycleState.inactive) {
      if (controller == null) return;
      _controller = null;
      unawaited(controller.dispose());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && controller == null) {
      unawaited(_setUpCamera());
    }
  }

  // ── Setup ──────────────────────────────────────────────────────────────────

  Future<void> _setUpCamera() async {
    try {
      if (!await PermissionService.requestCamera()) {
        if (mounted) setState(() => _error = 'Camera permission is needed');
        return;
      }
      // Asked up front rather than at the first recording: being prompted the
      // moment you press and hold loses the clip you were trying to take.
      await PermissionService.requestMicrophone();

      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _error = 'No camera on this device');
        return;
      }
      await _startController(_cameraIndex);
    } catch (e) {
      LogService.e('Camera', 'setup failed: $e');
      if (mounted) setState(() => _error = 'Camera unavailable');
    }
  }

  Future<void> _startController(int index) async {
    final previous = _controller;
    _controller = null;
    await previous?.dispose();

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high, // 720p — about what the chat uploads anyway
      enableAudio: true,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(_flash);
    } catch (e) {
      LogService.e('Camera', 'initialize failed: $e');
      if (mounted) setState(() => _error = 'Camera unavailable');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _cameraIndex = index;
      _error = null;
    });
  }

  Future<void> _loadRecent() async {
    final items = await MediaLibraryService.recent();
    if (!mounted) return;
    setState(() => _recent = items);
  }

  // ── Capture ────────────────────────────────────────────────────────────────

  bool get _ready => _controller?.value.isInitialized == true && !_busy;

  Future<void> _onShutterTap() async {
    if (!_ready) return;
    if (_recording) return _stopRecording();
    if (_videoMode) return _startRecording();
    await _takePhoto();
  }

  /// Press-and-hold records whichever mode is selected, then sends on release —
  /// the gesture people already have in their fingers.
  Future<void> _onHoldStart() async {
    if (!_ready || _recording) return;
    await _startRecording();
  }

  Future<void> _onHoldEnd() async {
    if (_recording) await _stopRecording();
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _busy = true);
    try {
      final shot = await controller.takePicture();
      await _confirmAndFinish(
          CapturedMedia(File(shot.path), MessageType.image));
    } catch (e) {
      LogService.e('Camera', 'takePicture failed: $e');
      _showError('Could not take the photo');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
    } catch (e) {
      LogService.e('Camera', 'startVideoRecording failed: $e');
      _showError('Could not start recording');
    }
  }

  Future<void> _stopRecording() async {
    final controller = _controller;
    _recordTimer?.cancel();
    _recordTimer = null;
    if (controller == null) return;
    try {
      final clip = await controller.stopVideoRecording();
      if (mounted) setState(() => _recording = false);
      // A tap that lands as a long press produces a sub-second clip nobody
      // meant to record; treat it as a mis-tap rather than sending it.
      if (_elapsed < const Duration(seconds: 1)) {
        LogService.i('Camera', 'discarding accidental sub-second clip');
        return;
      }
      await _confirmAndFinish(
          CapturedMedia(File(clip.path), MessageType.video));
    } catch (e) {
      LogService.e('Camera', 'stopVideoRecording failed: $e');
      if (mounted) setState(() => _recording = false);
      _showError('Could not save the recording');
    }
  }

  // ── Chrome actions ─────────────────────────────────────────────────────────

  Future<void> _toggleFlash() async {
    const cycle = [FlashMode.off, FlashMode.auto, FlashMode.torch];
    final next = cycle[(cycle.indexOf(_flash) + 1) % cycle.length];
    setState(() => _flash = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (e) {
      LogService.w('Camera', 'setFlashMode($next) failed: $e');
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _recording) return;
    await _startController((_cameraIndex + 1) % _cameras.length);
  }

  /// Bottom-left tile: the full system picker, for anything older than the
  /// strip holds.
  Future<void> _openSystemPicker() async {
    try {
      final picked = await _picker.pickMultipleMedia(imageQuality: 70);
      if (picked.isEmpty) return;
      _finish([
        for (final xf in picked)
          CapturedMedia(File(xf.path), mediaTypeForPath(xf.path)),
      ]);
    } catch (e) {
      LogService.e('Camera', 'system picker failed: $e');
      _showError('Could not open the gallery');
    }
  }

  Future<void> _sendFromStrip(GalleryItem item) async {
    setState(() => _busy = true);
    final file = await MediaLibraryService.fileFor(item.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (file == null) {
      _showError('That file is not available on this phone');
      return;
    }
    await _confirmAndFinish(CapturedMedia(
        file, item.isVideo ? MessageType.video : MessageType.image));
  }

  /// Shows [media] full-screen and only sends it if the user confirms.
  ///
  /// A shot used to go straight into the chat — a blurred photo was already
  /// sent by the time it appeared. Declining returns to the live viewfinder
  /// rather than closing the camera, so retaking is one tap.
  Future<void> _confirmAndFinish(CapturedMedia media) async {
    final send = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MediaPreviewScreen(media: media)),
    );
    if (!mounted || send != true) return;
    _finish([media]);
  }

  void _finish(List<CapturedMedia> media) {
    if (!mounted) return;
    Navigator.of(context).pop(media);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _CameraPreviewLayer(controller: _controller, error: _error),
          SafeArea(
            child: Column(
              children: [
                _CameraTopBar(
                  flash: _flash,
                  onClose: () => Navigator.of(context).pop(),
                  onToggleFlash: _toggleFlash,
                  onFlip: _cameras.length > 1 ? _flipCamera : null,
                ),
                if (_recording)
                  _RecordingPill(label: formatClipDuration(_elapsed)),
                const Spacer(),
                RecentMediaStrip(items: _recent, onTap: _sendFromStrip),
                _CameraBottomBar(
                  videoMode: _videoMode,
                  recording: _recording,
                  onShutterTap: _onShutterTap,
                  onHoldStart: _onHoldStart,
                  onHoldEnd: _onHoldEnd,
                  onModeChanged: (video) => setState(() => _videoMode = video),
                  onOpenGallery: _openSystemPicker,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
