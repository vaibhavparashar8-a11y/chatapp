import 'package:flutter/material.dart';

import '../../theme/chat_theme.dart';

/// VIDEO | PHOTO under the shutter. The active mode is accented; tapping the
/// other one switches.
class CameraModeSwitch extends StatelessWidget {
  final bool videoMode;
  final ValueChanged<bool> onChanged;

  const CameraModeSwitch({
    super.key,
    required this.videoMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ModeLabel(
          label: 'VIDEO',
          active: videoMode,
          onTap: () => onChanged(true),
        ),
        const SizedBox(width: 28),
        _ModeLabel(
          label: 'PHOTO',
          active: !videoMode,
          onTap: () => onChanged(false),
        ),
      ],
    );
  }
}

class _ModeLabel extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModeLabel({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 1.2,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? ChatTheme.accent : ChatTheme.textFaint,
          ),
        ),
      ),
    );
  }
}
