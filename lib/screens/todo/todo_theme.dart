part of '../todo_screen.dart';

// ── Dark-violet palette ──────────────────────────────────────────────────────
// Mirrors the chat screen so both halves of the app feel like one product.
// Hex values are lifted directly from chat_screen.dart.

const Color _kTodoBg = Color(0xFF0F0F1E); // scaffold background
const Color _kTodoAppBar1 = Color(0xFF1C0544); // app-bar gradient start
const Color _kTodoAppBar2 = Color(0xFF3D1A78); // app-bar gradient end
const Color _kTodoHeaderBar = Color(0xFF13102A); // stats strip under the app bar
const Color _kTodoCard = Color(0xFF1A1040); // task card / dialog surface
const Color _kTodoField = Color(0xFF1E1A40); // text-field fill
const Color _kTodoAccent = Color(0xFF7C3AED); // primary violet
const Color _kTodoAccentDeep = Color(0xFF6D28D9); // buttons / FAB
const Color _kTodoAccentLight = Color(0xFFA78BFA); // light violet — meta / labels
const Color _kTodoEmerald = Color(0xFF34D399); // success (completed progress)

const Color _kTodoText = Colors.white;
const Color _kTodoTextDim = Colors.white70;
const Color _kTodoTextFaint = Colors.white38;
const Color _kTodoDivider = Colors.white12;

// Dark AlertDialog styling, applied per-dialog so the todo dialogs match the
// chat aesthetic regardless of the system light/dark setting.
const _kTodoDialogTitle = TextStyle(
    color: _kTodoText, fontSize: 18, fontWeight: FontWeight.w600);
const _kTodoDialogContent = TextStyle(color: _kTodoTextDim, fontSize: 14);

/// `builder` for showDatePicker / showTimePicker so they render dark-violet
/// instead of flashing the system light theme mid-flow.
Widget _todoPickerTheme(BuildContext context, Widget? child) {
  return Theme(
    data: Theme.of(context).copyWith(
      colorScheme: const ColorScheme.dark(
        primary: _kTodoAccentLight,
        onPrimary: _kTodoBg,
        surface: _kTodoCard,
        onSurface: _kTodoText,
      ),
    ),
    child: child ?? const SizedBox.shrink(),
  );
}
