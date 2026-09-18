import 'package:flutter/material.dart';

import '../../theme/chat_theme.dart';

/// The shutter: a white ring that fills red while a clip is recording.
///
/// Tap takes a photo (or stops/starts a clip in video mode); press-and-hold
/// records for as long as the finger is down, the way WhatsApp's does.
class CaptureButton extends StatelessWidget {
  final bool recording;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  const CaptureButton({
    super.key,
    required this.recording,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: (_) => onHoldStart(),
      onLongPressEnd: (_) => onHoldEnd(),
      child: AnimatedContainer(
        duration: ChatTheme.fast,
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: recording ? ChatTheme.danger : Colors.white,
            width: 4,
          ),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: ChatTheme.fast,
            width: recording ? 30 : 58,
            height: recording ? 30 : 58,
            decoration: BoxDecoration(
              color: recording ? ChatTheme.danger : Colors.white,
              // A square core while recording reads as "stop", a circle as
              // "shoot" — the same two shapes every camera app uses.
              shape: recording ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: recording ? BorderRadius.circular(6) : null,
            ),
          ),
        ),
      ),
    );
  }
}
