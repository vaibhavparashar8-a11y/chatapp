part of '../chat_screen.dart';

// ── Aurora backdrop ──────────────────────────────────────────────────────────

/// Soft violet light behind the message list.
///
/// Three off-screen radial pools rather than one flat fill, which is what stops
/// a long scroll of bubbles from reading as a grey slab. Deliberately **static**
/// — an animated full-screen gradient repaints every frame, and one of the two
/// phones already struggles with video decode (see §7); depth here, motion on
/// the things the user actually touches.
class _AuroraBackground extends StatelessWidget {
  final Widget child;
  const _AuroraBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: ChatTheme.surface0),
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.9, -1.1),
                  radius: 1.1,
                  colors: [Color(0x557C3AED), Color(0x00000000)],
                ),
              ),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(1.2, -0.2),
                  radius: 0.9,
                  colors: [Color(0x33D946EF), Color(0x00000000)],
                ),
              ),
            ),
          ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.6, 1.2),
                  radius: 1.0,
                  colors: [Color(0x3B4F46E5), Color(0x00000000)],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

// ── Send button ──────────────────────────────────────────────────────────────

/// Gradient send button that dips under the finger.
///
/// The press response is the point: a flat circle that does nothing on touch is
/// the single most "unfinished"-feeling control in a chat app.
class _SendButton extends StatefulWidget {
  final VoidCallback onTap;
  const _SendButton({required this.onTap});

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.88 : 1,
        duration: ChatTheme.fast,
        curve: ChatTheme.press,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: ChatTheme.sendButton,
            shape: BoxShape.circle,
            boxShadow: ChatTheme.glow(ChatTheme.violet,
                blur: _down ? 6 : 14, opacity: _down ? 0.25 : 0.5),
          ),
          child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

// ── Date separator ───────────────────────────────────────────────────────────

/// "Today" / "Yesterday" / "Fri 14 Aug" chip between days.
class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: ChatTheme.surface2.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ChatTheme.hairline),
        ),
        child: Text(
          formatDateSeparator(date),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: ChatTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}
