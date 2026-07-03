part of '../message_bubble.dart';

// ── Inline video player ──────────────────────────────────────────────────────

class _InlineVideoPlayer extends StatefulWidget {
  final String url;
  final String fileName;
  final String messageId;

  const _InlineVideoPlayer({
    required this.url,
    required this.fileName,
    required this.messageId,
  });

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _started = false;
  bool _error = false;
  bool _openingExternal = false;

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
    } catch (e, st) {
      LogService.e('VideoPlayer', 'init failed — url=${widget.url} err=$e\n$st');
      if (mounted) setState(() { _started = false; _error = true; });
    }
  }

  Future<void> _openExternal() async {
    if (_openingExternal) return;
    setState(() => _openingExternal = true);
    try {
      final path = await _savePath(widget.fileName);
      await Dio().download(widget.url, path);
      await OpenFile.open(path);
    } catch (e, st) {
      LogService.e('VideoPlayer', 'open external failed — ${widget.fileName} err=$e\n$st');
    } finally {
      if (mounted) setState(() => _openingExternal = false);
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
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline, color: Colors.redAccent, size: 32),
                              const SizedBox(height: 4),
                              const Text('Failed to play video',
                                  style: TextStyle(color: Colors.white54, fontSize: 11)),
                              const SizedBox(height: 8),
                              GestureDetector(
                                onTap: _openingExternal ? null : _openExternal,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white12,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: _openingExternal
                                      ? const SizedBox(width: 14, height: 14,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                                      : const Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(Icons.open_in_new, color: Colors.white70, size: 13),
                                          SizedBox(width: 4),
                                          Text('Open externally',
                                              style: TextStyle(color: Colors.white70, fontSize: 11)),
                                        ]),
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text('or tap card to retry',
                                  style: TextStyle(color: Colors.white30, fontSize: 10)),
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
