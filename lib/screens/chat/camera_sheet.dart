part of '../chat_screen.dart';

// ── Camera mode sheet ────────────────────────────────────────────────────────

/// Asked after the single "Camera" attach tile is tapped: still or clip.
///
/// Pops [MessageType.image] or [MessageType.video], or null when dismissed.
class _CameraModeSheet extends StatelessWidget {
  const _CameraModeSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        decoration: BoxDecoration(
          color: ChatTheme.surface1,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _CameraModeTile(
              icon: Icons.photo_camera_rounded,
              label: 'Take photo',
              color: const Color(0xFF8B5CF6),
              onTap: () => Navigator.pop(context, MessageType.image),
            ),
            _CameraModeTile(
              icon: Icons.videocam_rounded,
              label: 'Record video',
              color: const Color(0xFFEF4444),
              onTap: () => Navigator.pop(context, MessageType.video),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row of [_CameraModeSheet]: gradient icon chip plus a label.
class _CameraModeTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CameraModeTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color, Color.lerp(color, Colors.black, 0.35)!],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
