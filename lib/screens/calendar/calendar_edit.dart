part of '../calendar_screen.dart';

// ── Add / edit a reminder ────────────────────────────────────────────────────
// The calendar writes to the SAME task list as the todo screen, through
// TaskStore — so anything added here shows up there, and vice versa. Each
// mutation does the same three things the todo screen does: update the local
// list, (re)arm or cancel the OS alarm, and write through to the Firestore doc
// when the task is backed by one.

/// What the add/edit sheet returned.
class _TaskEdit {
  final String title;
  final TimeOfDay time;
  final Recurrence recurrence;
  const _TaskEdit(this.title, this.time, this.recurrence);
}

extension _CalendarEditing on _CalendarScreenState {
  /// FAB — add a reminder on the selected day.
  Future<void> _addForSelectedDay() async {
    final result = await _showEditSheet(
      title: 'New reminder',
      initialTitle: '',
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      initialRecurrence: Recurrence.none,
    );
    if (result == null || !mounted) return;

    final when = DateTime(_selected.year, _selected.month, _selected.day,
        result.time.hour, result.time.minute);
    final task = Task(
      DateTime.now().millisecondsSinceEpoch.toString(),
      result.title,
      start: when,
      recurrence: result.recurrence,
      createdBy: mySenderId,
    );

    applyChange(() => _tasks.insert(0, task));
    await _save();
    final ok = await NotificationService.scheduleReminder(
      id: task.id.hashCode,
      title: task.title,
      scheduledTime: when,
      recurrence: task.recurrence,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Reminder set for ${formatDue(when)}'
          : 'Saved, but the alarm could not be set.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Tap a row — change its title, time or repeat.
  Future<void> _editTask(Task task) async {
    final at = task.occurrenceOn(_selected) ?? task.start!;
    final result = await _showEditSheet(
      title: 'Edit reminder',
      initialTitle: task.title,
      initialTime: TimeOfDay(hour: at.hour, minute: at.minute),
      initialRecurrence: task.recurrence,
    );
    if (result == null || !mounted) return;

    // Editing a repeating reminder moves the whole series, not one occurrence:
    // the model has no per-occurrence overrides, so keep the original start
    // DATE and change only the time. Editing a one-shot from another day would
    // otherwise silently move it to the day being viewed.
    final base = task.start!;
    final when = DateTime(
        base.year, base.month, base.day, result.time.hour, result.time.minute);

    applyChange(() {
      task.title = result.title;
      task.start = when;
      task.recurrence = result.recurrence;
    });
    await _save();

    await NotificationService.cancelReminderGroup(task.id.hashCode);
    final docId = task.backingDocId;
    if (docId != null) {
      await NotificationService.cancelReminder(
          NotificationService.docNotifId(docId));
    }
    // A notify-only task (set with "Remind me" unticked on the todo screen)
    // has no alarm here; editing its time on the calendar must not create one.
    if (!task.done && task.remindsMe) {
      await NotificationService.scheduleReminder(
        id: task.id.hashCode,
        title: task.title,
        scheduledTime: when,
        recurrence: task.recurrence,
      );
    }
    if (docId != null) {
      unawaited(ReminderService.updateSharedTask(docId,
              title: task.title,
              scheduledAt: when,
              recurrence: task.recurrence)
          .catchError(
              (e) => LogService.w('calendar', 'reminder sync failed: $e')));
    }
  }

  Future<void> _toggleDone(Task task, bool done) async {
    applyChange(() => task.done = done);
    await _save();
    final docId = task.backingDocId;
    if (docId != null) {
      unawaited(ReminderService.updateSharedTask(docId, done: done).catchError(
          (e) => LogService.w('calendar', 'done sync failed: $e')));
    }
  }

  Future<void> _deleteTask(Task task) async {
    final docId = task.backingDocId;
    unawaited(NotificationService.cancelReminderGroup(task.id.hashCode));
    if (docId != null) {
      unawaited(NotificationService.cancelReminder(
          NotificationService.docNotifId(docId)));
    }
    applyChange(() => _tasks.removeWhere((t) => t.id == task.id));
    await _save();
    if (docId != null) {
      unawaited(ReminderService.deleteSharedTask(docId).catchError(
          (e) => LogService.w('calendar', 'shared task delete failed: $e')));
    }
  }

  /// The shared add/edit dialog. Returns null when cancelled.
  Future<_TaskEdit?> _showEditSheet({
    required String title,
    required String initialTitle,
    required TimeOfDay initialTime,
    required Recurrence initialRecurrence,
  }) =>
      showDialog<_TaskEdit>(
        context: context,
        builder: (_) => _TaskEditDialog(
          heading: title,
          initialTitle: initialTitle,
          initialTime: initialTime,
          initialRecurrence: initialRecurrence,
        ),
      );
}

/// Title / time / repeat editor, shared by add and edit.
///
/// A StatefulWidget rather than a StatefulBuilder so it owns its
/// [TextEditingController] and disposes it in [State.dispose] — disposing it
/// right after `showDialog` returns tears it down while the dialog's exit
/// animation is still rendering the field, which throws.
class _TaskEditDialog extends StatefulWidget {
  final String heading;
  final String initialTitle;
  final TimeOfDay initialTime;
  final Recurrence initialRecurrence;

  const _TaskEditDialog({
    required this.heading,
    required this.initialTitle,
    required this.initialTime,
    required this.initialRecurrence,
  });

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialTitle);
  late TimeOfDay _time = widget.initialTime;
  late Recurrence _recurrence = widget.initialRecurrence;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return; // nothing to save — keep the dialog open
    Navigator.pop(context, _TaskEdit(text, _time, _recurrence));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kAppCard,
      titleTextStyle: kAppDialogTitle,
      title: Text(widget.heading),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(color: kAppText),
            cursorColor: kAppAccentLight,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              hintText: 'What is it?',
              hintStyle: TextStyle(color: kAppTextFaint),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: kAppDivider)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: kAppAccentLight)),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule, color: kAppAccentLight),
            title: const Text('Time', style: TextStyle(color: kAppText)),
            trailing: Text(_time.format(context),
                style: const TextStyle(
                    color: kAppText, fontWeight: FontWeight.w600)),
            onTap: () async {
              final picked = await showTimePicker(
                  context: context,
                  initialTime: _time,
                  builder: appPickerTheme);
              if (picked != null && mounted) setState(() => _time = picked);
            },
          ),
          const Divider(color: kAppDivider, height: 12),
          const Row(children: [
            Icon(Icons.repeat, size: 18, color: kAppAccentLight),
            SizedBox(width: 10),
            Text('Repeat', style: TextStyle(color: kAppText)),
          ]),
          DropdownButton<Recurrence>(
            value: _recurrence,
            isExpanded: true,
            dropdownColor: kAppCard,
            style: const TextStyle(color: kAppText),
            iconEnabledColor: kAppAccentLight,
            onChanged: (v) =>
                setState(() => _recurrence = v ?? Recurrence.none),
            items: [
              for (final r in Recurrence.values)
                DropdownMenuItem(value: r, child: Text(r.label)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: kAppTextDim),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(backgroundColor: kAppAccentDeep),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
