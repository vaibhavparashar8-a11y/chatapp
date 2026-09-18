part of '../camera_screen.dart';

// ── Preview ──────────────────────────────────────────────────────────────────

/// The live preview, or the reason there isn't one.
///
/// The preview is letterbox-free: `CameraPreview` reports the sensor's aspect
/// ratio, which almost never matches the phone's screen, so it is scaled to
/// cover and clipped — a black band top and bottom is exactly what makes an
/// in-app camera look like a debug screen.
class _CameraPreviewLayer extends StatelessWidget {
  final CameraController? controller;
  final String? error;

  const _CameraPreviewLayer({required this.controller, required this.error});

  @override
  Widget build(BuildContext context) {
    final message = error;
    if (message != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: ChatTheme.textSecondary),
            ),
          ),
        ),
      );
    }

    final cam = controller;
    if (cam == null || !cam.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white30),
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.width,
          height: size.width * cam.value.aspectRatio,
          child: CameraPreview(cam),
        ),
      ),
    );
  }
}

// ── Top bar ──────────────────────────────────────────────────────────────────

class _CameraTopBar extends StatelessWidget {
  final FlashMode flash;
  final VoidCallback onClose;
  final VoidCallback onToggleFlash;

  /// Null when the phone has a single lens — no point offering the flip.
  final VoidCallback? onFlip;

  const _CameraTopBar({
    required this.flash,
    required this.onClose,
    required this.onToggleFlash,
    required this.onFlip,
  });

  IconData get _flashIcon => switch (flash) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        _ => Icons.flash_on_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final flip = onFlip;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: onClose,
            tooltip: 'Close',
          ),
          const Spacer(),
          IconButton(
            icon: Icon(_flashIcon,
                color: flash == FlashMode.off
                    ? Colors.white
                    : ChatTheme.accent),
            onPressed: onToggleFlash,
            tooltip: 'Flash',
          ),
          if (flip != null)
            IconButton(
              icon: const Icon(Icons.cameraswitch_rounded, color: Colors.white),
              onPressed: flip,
              tooltip: 'Switch camera',
            ),
        ],
      ),
    );
  }
}

/// The red dot + elapsed time shown while a clip is being recorded.
class _RecordingPill extends StatelessWidget {
  final String label;

  const _RecordingPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record_rounded,
              size: 12, color: ChatTheme.danger),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Bottom bar ───────────────────────────────────────────────────────────────

/// Gallery tile, shutter and mode switch — everything under the preview.
class _CameraBottomBar extends StatelessWidget {
  final bool videoMode;
  final bool recording;
  final VoidCallback onShutterTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final ValueChanged<bool> onModeChanged;
  final VoidCallback onOpenGallery;

  const _CameraBottomBar({
    required this.videoMode,
    required this.recording,
    required this.onShutterTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onModeChanged,
    required this.onOpenGallery,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      color: Colors.black.withValues(alpha: 0.35),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: _RoundIconButton(
                      icon: Icons.photo_library_rounded,
                      onTap: onOpenGallery,
                      tooltip: 'All media',
                    ),
                  ),
                ),
              ),
              CaptureButton(
                recording: recording,
                onTap: onShutterTap,
                onHoldStart: onHoldStart,
                onHoldEnd: onHoldEnd,
              ),
              // Balances the gallery tile so the shutter stays centred.
              const Expanded(child: SizedBox()),
            ],
          ),
          const SizedBox(height: 4),
          CameraModeSwitch(videoMode: videoMode, onChanged: onModeChanged),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.14),
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
