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
  // Changing this key forces AgoraVideoView to fully recreate its platform
  // surface, which re-attaches to the Agora engine after the app resumes
  // from background (the old surface becomes stale when the app is paused).
  Key _surfaceKey = UniqueKey();

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
            onPanUpdate: (d) {
              setState(() {
                _x = (_x + d.delta.dx).clamp(0, size.width - 120);
                _y = (_y + d.delta.dy).clamp(0, size.height - 200);
              });
            },
            // Flick upward OR drag above screen midpoint → expand to full call
            onPanEnd: (d) {
              final flickedUp = d.velocity.pixelsPerSecond.dy < -400;
              final draggedHigh = _y < size.height * 0.35;
              if (flickedUp || draggedHigh) widget.onTap();
            },
            child: Container(
              width: 120,
              height: 160,
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
