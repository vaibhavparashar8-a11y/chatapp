part of '../todo_screen.dart';

// ── Palette aliases ──────────────────────────────────────────────────────────
// The colours themselves now live in lib/theme/app_palette.dart so the calendar
// screen (and anything else outside this part-file family) can use them. The
// todo parts keep referring to them by their original private names, so this
// indirection avoids renaming hundreds of call sites for no behavioural gain.

const Color _kTodoBg = kAppBg;
const Color _kTodoAppBar1 = kAppBar1;
const Color _kTodoAppBar2 = kAppBar2;
const Color _kTodoHeaderBar = kAppHeaderBar;
const Color _kTodoCard = kAppCard;
const Color _kTodoField = kAppField;
const Color _kTodoAccent = kAppAccent;
const Color _kTodoAccentDeep = kAppAccentDeep;
const Color _kTodoAccentLight = kAppAccentLight;
const Color _kTodoEmerald = kAppEmerald;

const Color _kTodoText = kAppText;
const Color _kTodoTextDim = kAppTextDim;
const Color _kTodoTextFaint = kAppTextFaint;
const Color _kTodoDivider = kAppDivider;

const _kTodoDialogTitle = kAppDialogTitle;
const _kTodoDialogContent = kAppDialogContent;

/// `builder` for showDatePicker / showTimePicker — see [appPickerTheme].
Widget _todoPickerTheme(BuildContext context, Widget? child) =>
    appPickerTheme(context, child);
