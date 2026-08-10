import 'package:flutter/material.dart';

/// The app's dark-violet palette, shared by every screen so the chat, todo and
/// calendar halves read as one product.
///
/// These used to live as private `_kTodo*` constants inside
/// `screens/todo/todo_theme.dart`, which is a `part` file — so nothing outside
/// the todo screen could reach them. The todo parts still refer to them by
/// their old private names (aliased in `todo_theme.dart`), so this move is
/// behaviour-neutral.

const Color kAppBg = Color(0xFF0F0F1E); // scaffold background
const Color kAppBar1 = Color(0xFF1C0544); // app-bar gradient start
const Color kAppBar2 = Color(0xFF3D1A78); // app-bar gradient end
const Color kAppHeaderBar = Color(0xFF13102A); // strip under the app bar
const Color kAppCard = Color(0xFF1A1040); // card / dialog surface
const Color kAppField = Color(0xFF1E1A40); // text-field fill
const Color kAppAccent = Color(0xFF7C3AED); // primary violet
const Color kAppAccentDeep = Color(0xFF6D28D9); // buttons / FAB
const Color kAppAccentLight = Color(0xFFA78BFA); // light violet — meta / labels
const Color kAppEmerald = Color(0xFF34D399); // success / "theirs" accent
const Color kAppNow = Color(0xFFF87171); // the calendar's current-time line

const Color kAppText = Colors.white;
const Color kAppTextDim = Colors.white70;
const Color kAppTextFaint = Colors.white38;
const Color kAppDivider = Colors.white12;

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
