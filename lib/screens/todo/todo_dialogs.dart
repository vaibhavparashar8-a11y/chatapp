part of '../todo_screen.dart';

// ── Reminder-related dialogs ─────────────────────────────────────────────────
// Pulled out of _TodoScreenState to keep the screen lean. These are async
// helpers that only read state / show dialogs (no setState), so an extension
// is analyzer-clean.

extension _TodoDialogs on _TodoScreenState {
  /// Configure the daily task summary — a single on-device notification each
  /// morning listing the day's tasks as a ☐ checklist. Fully local (see
  /// [DigestService]); no account or network needed.
  Future<void> _showDigestSettings() async {
    final settings = await DigestService.load();
    if (!mounted) return;

    bool enabled = settings.enabled;
    var time = TimeOfDay(hour: settings.hour, minute: settings.minute);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kTodoCard,
          titleTextStyle: _kTodoDialogTitle,
          title: const Text('Daily task summary'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: _kTodoAccentLight,
                title: const Text('Morning summary notification',
                    style: TextStyle(color: _kTodoText)),
                subtitle: const Text(
                    'A daily notification listing the tasks due that day.',
                    style: TextStyle(color: _kTodoTextDim)),
                value: enabled,
                onChanged: (v) => setLocal(() => enabled = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: enabled,
                leading: const Icon(Icons.schedule, color: _kTodoAccentLight),
                title: const Text('Summary time',
                    style: TextStyle(color: _kTodoText)),
                trailing: Text(time.format(ctx),
                    style: const TextStyle(
                        color: _kTodoText, fontWeight: FontWeight.w600)),
                onTap: enabled
                    ? () async {
                        final picked = await showTimePicker(
                            context: ctx,
                            initialTime: time,
                            builder: _todoPickerTheme);
                        if (picked != null) setLocal(() => time = picked);
                      }
                    : null,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: _kTodoAccentDeep),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    try {
      await DigestService.save(DigestPrefs(
        enabled: enabled,
        hour: time.hour,
        minute: time.minute,
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(enabled
              ? 'Daily summary on — ${time.format(context)}'
              : 'Daily summary off'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      LogService.e('todo', 'save digest settings failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<DateTime?> _pickDateTime({DateTime? initial}) async {
    final now = DateTime.now();
    final init = initial != null && initial.isAfter(now)
        ? initial
        : now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Pick reminder date',
      builder: _todoPickerTheme,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? init),
      helpText: 'Pick reminder time',
      builder: _todoPickerTheme,
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}
