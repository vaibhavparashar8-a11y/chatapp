import 'package:flutter/material.dart';
import 'chat_theme.dart';

/// The app's dark-violet palette, shared by every screen so the chat, todo and
/// calendar halves read as one product.
///
/// These values are now **derived from [ChatTheme]** rather than being a second
/// set of hex literals. Before that they had quietly drifted: the todo card was
/// `#1A1040` while the chat panel was `#141024`, so switching tabs shifted the
/// background a shade. The todo `part` files still refer to them by their old
/// private names (aliased in `todo_theme.dart`), so this stays a rename-free
/// change.

const Color kAppBg = ChatTheme.surface0; // scaffold background
const Color kAppBar1 = Color(0xFF3B1E91); // app-bar gradient start
const Color kAppBar2 = Color(0xFF23124F); // app-bar gradient end
const Color kAppHeaderBar = ChatTheme.surface1; // strip under the app bar
const Color kAppCard = ChatTheme.surface1; // card / dialog surface
const Color kAppField = ChatTheme.surface2; // text-field fill
const Color kAppAccent = ChatTheme.violet; // primary violet
const Color kAppAccentDeep = ChatTheme.violetDeep; // buttons / FAB
const Color kAppAccentLight = ChatTheme.accent; // light violet — meta / labels
const Color kAppEmerald = ChatTheme.success; // success / "theirs" accent
const Color kAppNow = ChatTheme.danger; // the calendar's current-time line

const Color kAppText = ChatTheme.textPrimary;
const Color kAppTextDim = ChatTheme.textSecondary;
const Color kAppTextFaint = ChatTheme.textFaint;
const Color kAppDivider = ChatTheme.hairline;

/// Card surface with the same lit-from-one-direction gradient the chat bubbles
/// use — the cheapest way to stop a list of cards reading as flat rectangles.
const LinearGradient kAppCardGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF1B1533), Color(0xFF15112A)],
);

/// Shadow under a task card.
const List<BoxShadow> kAppCardShadow = [
  BoxShadow(color: Color(0x59000000), blurRadius: 12, offset: Offset(0, 4)),
];

/// Dark AlertDialog styling, applied per-dialog so dialogs match the app
/// aesthetic regardless of the system light/dark setting.
const kAppDialogTitle =
    TextStyle(color: kAppText, fontSize: 18, fontWeight: FontWeight.w600);
const kAppDialogContent = TextStyle(color: kAppTextDim, fontSize: 14);

/// `builder` for showDatePicker / showTimePicker so they render dark-violet
/// instead of flashing the system light theme mid-flow.
Widget appPickerTheme(BuildContext context, Widget? child) {
  return Theme(
    data: Theme.of(context).copyWith(
      colorScheme: const ColorScheme.dark(
        primary: kAppAccentLight,
        onPrimary: kAppBg,
        surface: kAppCard,
        onSurface: kAppText,
      ),
    ),
    child: child ?? const SizedBox.shrink(),
  );
}
