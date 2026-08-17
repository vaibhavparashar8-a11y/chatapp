part of '../chat_screen.dart';

// ── Attach sheet ─────────────────────────────────────────────────────────────

/// One tile in the attach sheet: a rounded gradient square with a label under
/// it. Replaces the old flat circle-in-a-scrolling-row look.
class _AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Tile gradient — [color] is the light end, darkened for the other.
  final Color color;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color, Color.lerp(color, Colors.black, 0.35)!],
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.30),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel itself: a rounded card with a grab handle and a wrapped grid of
/// [_AttachOption]s, so options stay on screen instead of hiding off the right
/// edge of a horizontal scroller.
class _AttachSheet extends StatelessWidget {
  final List<Widget> options;
  const _AttachSheet({required this.options});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1636),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, -2)),
        ],
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
          // maxCrossAxisExtent + mainAxisExtent, not a column count with an
          // aspect ratio: the latter scales tile HEIGHT with screen width, so
          // a wide layout blew the sheet up and overflowed the composer column.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 100,
              mainAxisExtent: 100,
            ),
            itemCount: options.length,
            itemBuilder: (_, i) => options[i],
          ),
        ],
      ),
    );
  }
}
