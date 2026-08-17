// lib/features/call/call_avatar.dart

import 'package:flutter/material.dart';
import '../../theme/chat_theme.dart';

/// The caller avatar on the waiting/audio call screen, with a ring that
/// breathes outward while the call is still connecting.
///
/// It is the only thing on that screen with anything to say before the other
/// side answers — a static circle reads as a frozen app when a call takes a few
/// seconds to connect. Set [active] false once connected: the pulse then stops
/// rather than animating forever behind a live conversation.
class PulsingAvatar extends StatefulWidget {
  final bool active;
  final double radius;

  const PulsingAvatar({super.key, required this.active, this.radius = 58});

  @override
  State<PulsingAvatar> createState() => _PulsingAvatarState();
}

class _PulsingAvatarState extends State<PulsingAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(PulsingAvatar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diameter = widget.radius * 2;
    return SizedBox(
      width: diameter * 1.8,
      height: diameter * 1.8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Two rings a half-cycle apart, so the expansion never fully stops.
          for (final offset in const [0.0, 0.5])
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                final t = (_ctrl.value + offset) % 1.0;
                return Opacity(
                  opacity: widget.active ? (1 - t) * 0.5 : 0,
                  child: Container(
                    width: diameter * (1 + t * 0.7),
                    height: diameter * (1 + t * 0.7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: ChatTheme.accent.withValues(alpha: 0.6)),
                    ),
                  ),
                );
              },
            ),
          Container(
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: ChatTheme.sendButton,
              boxShadow: ChatTheme.glow(ChatTheme.violet, blur: 28, opacity: 0.5),
            ),
            child: Icon(Icons.person_rounded,
                color: Colors.white.withValues(alpha: 0.92),
                size: widget.radius),
          ),
        ],
      ),
    );
  }
}
