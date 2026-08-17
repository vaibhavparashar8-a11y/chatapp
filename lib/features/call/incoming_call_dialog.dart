// lib/features/call/incoming_call_dialog.dart

import 'package:flutter/material.dart';
import '../../theme/chat_theme.dart';
import 'call_avatar.dart';

class IncomingCallDialog extends StatelessWidget {
  final String callType;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallDialog({
    super.key,
    required this.callType,
    required this.onAccept,
    required this.onDecline,
  });

  bool get _isVideo => callType == 'video';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        decoration: BoxDecoration(
          // The dialog used to inherit the light Material default, so an
          // incoming call flashed a white card over the dark app.
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF241B49), ChatTheme.surface1],
          ),
          borderRadius: BorderRadius.circular(ChatTheme.panelRadius),
          border: Border.all(color: ChatTheme.hairline),
          boxShadow: const [
            BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 12)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Same pulsing ring as the outgoing call screen — a ringing phone
            // is the one moment the UI should feel alive.
            const PulsingAvatar(active: true, radius: 38),
            const SizedBox(height: 18),
            Text(
              _isVideo ? 'Incoming video call' : 'Incoming call',
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: ChatTheme.textPrimary,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tap to answer',
              style: TextStyle(color: ChatTheme.textFaint, fontSize: 13),
            ),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _AnswerButton(
                  icon: Icons.call_end_rounded,
                  label: 'Decline',
                  colors: const [Color(0xFFFF6B6B), Color(0xFFD32F2F)],
                  onTap: onDecline,
                ),
                _AnswerButton(
                  icon: _isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                  label: 'Accept',
                  colors: const [Color(0xFF4ADE80), Color(0xFF16A34A)],
                  onTap: onAccept,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Accept/decline button — gradient circle that dips on press.
class _AnswerButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final List<Color> colors;
  final VoidCallback onTap;

  const _AnswerButton({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_AnswerButton> createState() => _AnswerButtonState();
}

class _AnswerButtonState extends State<_AnswerButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.9 : 1,
        duration: ChatTheme.fast,
        curve: ChatTheme.press,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.colors,
                ),
                shape: BoxShape.circle,
                boxShadow: ChatTheme.glow(widget.colors.first,
                    blur: 20, opacity: 0.45),
              ),
              child: Icon(widget.icon, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 8),
            Text(
              widget.label,
              style: const TextStyle(
                  fontSize: 12,
                  color: ChatTheme.textSecondary,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
