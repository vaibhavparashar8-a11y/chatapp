part of '../chat_screen.dart';

// ── Floating video overlay (minimized video call) ───────────────────────────

class _FloatingVideoOverlay extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onEnd;
  const _FloatingVideoOverlay({super.key, required this.onTap, required this.onEnd});

  @override
  State<_FloatingVideoOverlay> createState() => _FloatingVideoOverlayState();
}

class _FloatingVideoOverlayState extends State<_FloatingVideoOverlay>
    with WidgetsBindingObserver {
  double _x = 16;
  double _y = 80;
  double _w = 120;
  double _h = 160;

  // Whether the current pan gesture started in the resize handle corner.
  bool _resizeMode = false;

  // Changing this key forces AgoraVideoView to fully recreate its platform
  // surface, which re-attaches to the Agora engine after the app resumes
  // from background (the old surface becomes stale when the app is paused).
  Key _surfaceKey = UniqueKey();

  static const _handleSize = 24.0;
  static const _minW = 80.0;
  static const _maxW = 260.0;
  static const _minH = 100.0;
  static const _maxH = 340.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _surfaceKey = UniqueKey());
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Stack(
      children: [
        Positioned(
          left: _x,
          top: _y,
          child: GestureDetector(
            onTap: widget.onTap,
            // Decide at touch-down whether this is a move or a resize gesture.
            onPanDown: (d) {
              _resizeMode = d.localPosition.dx > _w - _handleSize &&
                  d.localPosition.dy > _h - _handleSize;
            },
            onPanUpdate: (d) {
              setState(() {
                if (_resizeMode) {
                  _w = (_w + d.delta.dx).clamp(_minW, _maxW);
                  _h = (_h + d.delta.dy).clamp(_minH, _maxH);
                  // Keep overlay inside screen after resize
                  _x = _x.clamp(0, size.width - _w);
                  _y = _y.clamp(0, size.height - _h);
                } else {
                  _x = (_x + d.delta.dx).clamp(0, size.width - _w);
                  _y = (_y + d.delta.dy).clamp(0, size.height - _h);
                }
              });
            },
            // Only expand on a deliberate upward flick — never on position alone,
            // since the overlay often starts in the "upper" zone already.
            onPanEnd: (d) {
              if (!_resizeMode && d.velocity.pixelsPerSecond.dy < -600) {
                widget.onTap();
              }
              _resizeMode = false;
            },
            child: Container(
              width: _w,
              height: _h,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 8, spreadRadius: 1),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Keyed so the platform view is fully recreated on app resume
                    KeyedSubtree(
                      key: _surfaceKey,
                      child: CallService.currentRemoteUid != null
                          ? AgoraVideoView(
                              controller: VideoViewController.remote(
                                rtcEngine: CallService.engine,
                                canvas: VideoCanvas(uid: CallService.currentRemoteUid),
                                connection: RtcConnection(channelId: agoraChannel),
                              ),
                            )
                          : AgoraVideoView(
                              controller: VideoViewController(
                                rtcEngine: CallService.engine,
                                canvas: const VideoCanvas(uid: 0),
                              ),
                            ),
                    ),
                    // End-call button (top-right)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onEnd,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.call_end,
                              color: Colors.white, size: 14),
                        ),
                      ),
                    ),
                    // Resize handle (bottom-right corner) — visual indicator only;
                    // the pan logic above detects touches in this area via _resizeMode.
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: _handleSize,
                        height: _handleSize,
                        decoration: const BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(6),
                            bottomRight: Radius.circular(10),
                          ),
                        ),
                        child: const Icon(Icons.open_in_full_rounded,
                            size: 12, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
