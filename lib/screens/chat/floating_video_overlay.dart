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
  // Geometry lives in CallService (reset on joinCall) because this State is
  // destroyed by the epoch key-bump every time the user returns from
  // CallScreen — local fields would snap the overlay back to defaults
  // mid-call. Reading here restores the last size/position of the same call.
  double _x = CallService.overlayX;
  double _y = CallService.overlayY;
  double _w = CallService.overlayW;
  double _h = CallService.overlayH;

  /// Set once a gesture has actually moved the overlay. A tap that ends after
  /// any real movement must not be treated as "restore full screen" — nudging
  /// the pip while repositioning it used to throw the user into the call
  /// screen. Reset on every pan-down.
  bool _moved = false;

  // Changing this key forces AgoraVideoView to fully recreate its platform
  // surface, which re-attaches to the Agora engine after the app resumes
  // from background (the old surface becomes stale when the app is paused).
  Key _surfaceKey = UniqueKey();

  // Comfortably larger than the old 24: the handle is now the resize target
  // itself, and a corner too small to hit reliably is what made people grab
  // the video surface instead and trip the restore-on-tap.
  static const _handleSize = 36.0;
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

  /// Drag the overlay by [delta], clamped inside a screen of [size].
  void _move(Offset delta, Size size) {
    if (delta.distance > 0) _moved = true;
    setState(() {
      _x = (_x + delta.dx).clamp(0, size.width - _w);
      _y = (_y + delta.dy).clamp(0, size.height - _h);
      _persist();
    });
  }

  /// Grow/shrink from the bottom-right corner by [delta].
  ///
  /// When the size is pinned at a clamp bound the delta would be silently
  /// absorbed and the drag would feel "stuck", so it falls through to a move —
  /// the same fallback the old combined gesture had.
  void _resize(Offset delta, Size size) {
    final newW = (_w + delta.dx).clamp(_minW, _maxW);
    final newH = (_h + delta.dy).clamp(_minH, _maxH);
    if (newW == _w && newH == _h) {
      _move(delta, size);
      return;
    }
    setState(() {
      _w = newW;
      _h = newH;
      // Keep the overlay inside the screen after resizing.
      _x = _x.clamp(0, size.width - _w);
      _y = _y.clamp(0, size.height - _h);
      _persist();
    });
  }

  /// Store geometry in CallService so the next reconstruction (return from
  /// CallScreen) restores the same size/position for this call.
  void _persist() {
    CallService.overlayX = _x;
    CallService.overlayY = _y;
    CallService.overlayW = _w;
    CallService.overlayH = _h;
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
            // Restore only on a clean tap. A gesture that moved the overlay is
            // a reposition, never a request to go full screen.
            onTap: () {
              if (!_moved) widget.onTap();
            },
            onPanDown: (_) => _moved = false,
            onPanUpdate: (d) => _move(d.delta, size),
            // Only expand on a deliberate upward flick — never on position alone,
            // since the overlay often starts in the "upper" zone already.
            onPanEnd: (d) {
              if (d.velocity.pixelsPerSecond.dy < -600) widget.onTap();
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
                          ? CallService
                              .remoteVideoView(CallService.currentRemoteUid!)
                          : CallService.localVideoView(),
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
                    // Resize handle (bottom-right corner). It owns its own
                    // gestures rather than being a painted hint the parent
                    // hit-tests: an opaque child detector consumes the touch,
                    // so a tap or a wobble while grabbing the corner can no
                    // longer fall through to the parent's restore-on-tap.
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {}, // absorb — never restores full screen
                        onPanUpdate: (d) => _resize(d.delta, size),
                        child: Container(
                          width: _handleSize,
                          height: _handleSize,
                          decoration: const BoxDecoration(
                            color: Colors.white30,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                            ),
                          ),
                          child: const Align(
                            alignment: Alignment.bottomRight,
                            child: Padding(
                              padding: EdgeInsets.only(right: 3, bottom: 3),
                              child: Icon(Icons.open_in_full_rounded,
                                  size: 14, color: Colors.white),
                            ),
                          ),
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
