import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/captured_media.dart';
import '../models/message.dart';
import '../services/log_service.dart';
import '../theme/chat_theme.dart';

/// Review-before-send for one captured or picked item.
///
/// A shot used to go straight into the chat: a blurred photo or a mis-framed
/// clip was already sent by the time it appeared. This sits between the camera
/// and the send — back returns to the viewfinder with nothing sent, the send
/// button confirms.
///
/// Pops `true` to send, `false`/null to discard and keep shooting.
class MediaPreviewScreen extends StatefulWidget {
  final CapturedMedia media;

  const MediaPreviewScreen({super.key, required this.media});

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  VideoPlayerController? _video;
  bool _videoFailed = false;

  bool get _isVideo => widget.media.type == MessageType.video;

  @override
  void initState() {
    super.initState();
    if (_isVideo) _initVideo();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _initVideo() async {
    final controller = VideoPlayerController.file(widget.media.file);
    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _video = controller);
      await controller.play();
    } catch (e) {
      LogService.e('MediaPreview', 'video init failed: $e');
      // Deliberately not awaited: disposing a controller that never
      // initialised can hang on a platform call that never answers, which
      // would leave this screen on its spinner forever.
      unawaited(controller.dispose().catchError((Object err) =>
          LogService.w('MediaPreview', 'dispose after failure: $err')));
      // The clip is still on disk and still sendable — only the preview is
      // missing, so this must not block the send button.
      if (mounted) setState(() => _videoFailed = true);
    }
  }

  void _togglePlay() {
    final video = _video;
    if (video == null) return;
    setState(() {
      video.value.isPlaying ? video.pause() : video.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: _buildMedia()),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: Colors.white),
                    tooltip: 'Back to camera',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
                const Spacer(),
                _buildSendBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMedia() {
    if (!_isVideo) {
      return Image.file(
        widget.media.file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const _PreviewUnavailable(
          label: 'Preview unavailable',
        ),
      );
    }
    final video = _video;
    if (_videoFailed) {
      return const _PreviewUnavailable(label: 'Preview unavailable');
    }
    if (video == null) {
      return const SizedBox(
        width: 28,
        height: 28,
        child:
            CircularProgressIndicator(strokeWidth: 2, color: Colors.white30),
      );
    }
    return GestureDetector(
      onTap: _togglePlay,
      child: AspectRatio(
        aspectRatio: video.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(video),
            if (!video.value.isPlaying)
              const Icon(Icons.play_arrow_rounded,
                  size: 64, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _buildSendBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.replay_rounded, color: Colors.white70),
            label: const Text('Retake',
                style: TextStyle(color: Colors.white70)),
          ),
          FloatingActionButton(
            heroTag: 'preview-send',
            backgroundColor: ChatTheme.violet,
            tooltip: 'Send',
            onPressed: () => Navigator.of(context).pop(true),
            child: const Icon(Icons.send_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// Shown when the file cannot be drawn — the send stays available, since the
/// file itself is fine.
class _PreviewUnavailable extends StatelessWidget {
  final String label;

  const _PreviewUnavailable({required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_rounded, color: Colors.white24, size: 44),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: ChatTheme.textSecondary)),
      ],
    );
  }
}
