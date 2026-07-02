part of '../message_bubble.dart';

// ── Inline video player ──────────────────────────────────────────────────────

class _InlineVideoPlayer extends StatefulWidget {
  final String url;
  final String fileName;
  final String? mediaIv; // kept for API compat, no longer used
  final String messageId;

  const _InlineVideoPlayer({
    required this.url,
    required this.fileName,
    required this.messageId,
    this.mediaIv,
  });

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _started = false;
  bool _error = false;

  Future<void> _start() async {
    setState(() { _started = true; _error = false; });
    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      _controller = ctrl;
      ctrl.addListener(() { if (mounted) setState(() {}); });
      await ctrl.initialize();
      if (mounted) {
        setState(() => _initialized = true);
        ctrl.play();
      }
    } catch (e) {
      debugPrint('VideoPlayer: init failed — $e');
      if (mounted) setState(() { _started = false; _error = true; });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      return Stack(
        children: [
          GestureDetector(
            onTap: _start,
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 220,
                    height: 160,
                    color: Colors.black87,
                    child: _error
                        ? const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.error_outline, color: Colors.redAccent, size: 36),
                              SizedBox(height: 6),
                              Text('Failed to load video',
                                  style: TextStyle(color: Colors.white54, fontSize: 12)),
                              SizedBox(height: 2),
                              Text('Tap to retry',
                                  style: TextStyle(color: Colors.white38, fontSize: 11)),
                            ],
                          )
                        : const Icon(Icons.videocam, color: Colors.white30, size: 48),
                  ),
                  if (!_error)
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: const Icon(Icons.play_arrow,
                          color: Colors.white, size: 36),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: _DownloadButton(
              url: widget.url,
              fileName: widget.fileName,
              messageType: MessageType.video,
            ),
          ),
        ],
      );
    }

    if (!_initialized) {
      return Container(
        width: 220,
        height: 160,
        decoration: const BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: const Center(
            child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final isPlaying = _controller!.value.isPlaying;
    return Stack(
      alignment: Alignment.center,
      children: [
        ClipRRect(
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(12)),
          child: GestureDetector(
            onTap: () {
              isPlaying ? _controller!.pause() : _controller!.play();
            },
            child: SizedBox(
              width: 220,
              height: 160,
              child: VideoPlayer(_controller!),
            ),
          ),
        ),
        if (!isPlaying)
          GestureDetector(
            onTap: () => _controller!.play(),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(26),
              ),
              child: const Icon(Icons.play_arrow,
                  color: Colors.white, size: 36),
            ),
          ),
        Positioned(
          top: 6,
          right: 6,
          child: _DownloadButton(
            url: widget.url,
            fileName: widget.fileName,
            messageType: MessageType.video,
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: VideoProgressIndicator(
            _controller!,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: Color(0xFF7C3AED),
              backgroundColor: Colors.white24,
            ),
          ),
        ),
      ],
    );
  }
}
