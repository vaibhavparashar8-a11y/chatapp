// lib/theme/chat_theme.dart

import 'package:flutter/material.dart';

/// Design tokens for the chat and call surfaces.
///
/// These used to be raw `Color(0xFF…)` literals scattered across
/// `chat_screen.dart`, `message_bubble.dart` and the call screens, which is why
/// the UI drifted into looking flat and slightly inconsistent — three files had
/// three different "panel" purples. Everything visual now comes from here, so a
/// change lands everywhere at once.
///
/// The palette is one violet family on near-black: deep enough for a dark room,
/// saturated enough that the accent reads as deliberate rather than grey.
class ChatTheme {
  ChatTheme._();

  // ── Surfaces (darkest → raised) ────────────────────────────────────────────

  /// Page base, behind the aurora glow.
  static const surface0 = Color(0xFF0B0917);

  /// Panels that sit on the page: attach sheet, emoji panel, composer.
  static const surface1 = Color(0xFF141024);

  /// Raised elements on a panel: input pill, chips, incoming bubbles.
  static const surface2 = Color(0xFF1E1838);

  /// Hairline between stacked surfaces. Deliberately faint — a visible border
  /// flattens the depth the gradients create.
  static const hairline = Color(0x14FFFFFF);

  // ── Brand ──────────────────────────────────────────────────────────────────

  static const violet = Color(0xFF7C3AED);
  static const violetLight = Color(0xFF9F67FF);
  static const violetDeep = Color(0xFF5B21B6);

  /// Text/icon accent on dark surfaces.
  static const accent = Color(0xFFA78BFA);

  /// Read ticks, "online".
  static const success = Color(0xFF34D399);
  static const danger = Color(0xFFF87171);

  // ── Text ───────────────────────────────────────────────────────────────────

  static const textPrimary = Color(0xFFF3F0FF);
  static const textSecondary = Color(0xB3FFFFFF);
  static const textFaint = Color(0x66FFFFFF);

  // ── Gradients ──────────────────────────────────────────────────────────────

  /// Outgoing bubble. Light-to-deep top-left → bottom-right, so a column of
  /// bubbles reads as lit from one direction instead of as flat blocks.
  static const myBubble = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [violetLight, violetDeep],
  );

  /// Incoming bubble — the same move, far more subtle.
  static const theirBubble = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF241E42), Color(0xFF1A1530)],
  );

  static const appBar = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3B1E91), Color(0xFF23124F)],
  );

  static const sendButton = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [violetLight, violet],
  );

  // ── Glow ───────────────────────────────────────────────────────────────────

  /// Coloured shadow under an outgoing bubble. A tinted shadow (rather than
  /// black) is most of what makes the bubble look lit rather than pasted on.
  static List<BoxShadow> get bubbleGlow => const [
        BoxShadow(color: Color(0x4D6D28D9), blurRadius: 14, offset: Offset(0, 4)),
      ];

  static List<BoxShadow> get panelShadow => const [
        BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, -3)),
      ];

  static List<BoxShadow> glow(Color color, {double blur = 16, double opacity = 0.45}) =>
      [BoxShadow(color: color.withValues(alpha: opacity), blurRadius: blur)];

  // ── Shape ──────────────────────────────────────────────────────────────────

  static const bubbleRadius = 20.0;

  /// Corner on the "tail" side of the last bubble in a run.
  static const bubbleTailRadius = 6.0;
  static const panelRadius = 24.0;
  static const pillRadius = 24.0;

  // ── Motion ─────────────────────────────────────────────────────────────────
  //
  // One scale, so nothing in the app animates at a speed unrelated to
  // everything else. Kept short: a chat is used in bursts and slow transitions
  // read as lag.

  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 380);

  /// Decelerating — things arriving on screen.
  static const enter = Curves.easeOutCubic;

  /// A little overshoot for taps, so buttons feel physical.
  static const press = Curves.easeOutBack;
}
