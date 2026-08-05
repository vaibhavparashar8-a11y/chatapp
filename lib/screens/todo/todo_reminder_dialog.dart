part of '../todo_screen.dart';

// ── Reminder side effects ────────────────────────────────────────────────────
// The alarm-arming and Firestore-doc work behind the Set Reminder dialog.
// Neither calls setState (they only read state and route through _saveTodos),
// so an extension keeps them analyzer-clean and the screen lean.

extension _TodoReminderActions on _TodoScreenState {
  /// Arm this phone's alarm for [todo]. A rule the OS cannot repeat natively
  /// (every N days, monthly, …) has no schedule path yet — it must not
  /// silently degrade to a one-shot, so it is refused and logged until
  /// occurrence expansion lands. Nothing in the repeat picker produces one.
  Future<bool> _armLocalReminder(
          Task todo, DateTime when, Recurrence recurrence) =>
      NotificationService.scheduleReminder(
        id: todo.id.hashCode,
        title: todo.title,
        scheduledTime: when,
        recurrence: recurrence,
      );

  /// Create or update the Firestore reminder doc behind [todo] to match the
  /// user's [choice]. Every doc created here is linked back onto the task
  /// (`sharedId` for mirrored ones, `reminderDocId` for stored-only) so a
  /// later edit or delete can reach it.
  Future<void> _persistReminderDoc(
      Task todo, DateTime start, _ReminderChoice choice) async {
    final recurrence = choice.recurrence;

    if (todo.backingDocId != null) {
      // Already has a doc (shared, self, or remind-them). Push the new time to
      // it instead of creating a duplicate — for shared tasks the other side's
      // mirror reschedules from it.
      unawaited(ReminderService.updateSharedTask(todo.backingDocId!,
              scheduledAt: start, recurrence: recurrence)
          .catchError(
              (e) => LogService.w('todo', 'reminder time sync failed: $e')));
      return;
    }

    if (choice.remindOther) {
      final otherId = mySenderId == 'A' ? 'B' : 'A';
      try {
        final docId = await ReminderService.createReminder(
          forUser: otherId,
          title: todo.title,
          scheduledAt: start,
          addToList: choice.addToList,
          recurrence: recurrence,
          // Mirror any existing sub-tasks so they show up on their phone too.
          subtasks: choice.addToList ? _subtaskPayload(todo) : null,
        );
        if (docId != null) {
          // addToList tasks are mirrored (sharedId); others are stored-only.
          if (choice.addToList) {
            todo.sharedId = docId;
          } else {
            todo.reminderDocId = docId;
          }
          await _saveTodos();
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Notified'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } catch (e) {
        LogService.w('todo', 'notify the other person failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not notify. Please try again.'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
      return;
    }

    if (choice.remindSelf) {
      // "Remind me" only: store a private backup doc alongside the local
      // notification (already scheduled). locallyScheduled=true so the delivery
      // paths and the Cloud Function skip it — no duplicate push.
      try {
        final docId = await ReminderService.createReminder(
          forUser: mySenderId,
          title: todo.title,
          scheduledAt: start,
          addToList: false,
          locallyScheduled: true,
          recurrence: recurrence,
        );
        if (docId != null) {
          todo.reminderDocId = docId;
          await _saveTodos();
        }
      } catch (e) {
        // Backup is best-effort — the local reminder still fires. But surface
        // the failure rather than swallow it: a rejected write here means the
        // self reminder never reaches Firestore (its cross-device backup).
        LogService.e('todo', 'self reminder Firestore write failed: $e');
      }
    }
  }
}

// ── Set Reminder dialog ──────────────────────────────────────────────────────
// The "who gets reminded + how it repeats" dialog, pulled out of
// _TodoScreenState so the screen keeps only the orchestration. It owns no app
// state: it takes the task's current repeat, and returns the user's choices as
// a [_ReminderChoice] for _setReminder to apply.

/// What the user chose in the Set Reminder dialog.
class _ReminderChoice {
  final bool remindSelf;
  final bool remindOther;
  final bool addToList;
  final Recurrence recurrence;

  const _ReminderChoice({
    required this.remindSelf,
    required this.remindOther,
    required this.addToList,
    required this.recurrence,
  });
}

/// The repeats the picker offers — every [Recurrence] value. All of them map
/// to a native repeating alarm, so the OS owns the repeat and it survives
/// app-kill and reboot. Anything richer ("every N days", monthly) would need
/// occurrence expansion driven by the background worker, which is deliberately
/// out of scope.

class _SetReminderDialog extends StatefulWidget {
  /// The task's current repeat, pre-selected in the picker.
  final Recurrence initialRecurrence;

  /// The date/time already picked, used to name the weekday of a weekly repeat.
  final DateTime scheduledAt;

  const _SetReminderDialog({
    required this.initialRecurrence,
    required this.scheduledAt,
  });

  @override
  State<_SetReminderDialog> createState() => _SetReminderDialogState();
}

class _SetReminderDialogState extends State<_SetReminderDialog> {
  bool _remindSelf = true;
  bool _remindOther = false;
  bool _addToList = false;
  late Recurrence _recurrence = widget.initialRecurrence;


  Widget _check({
    required bool value,
    required String label,
    required ValueChanged<bool?> onChanged,
    double indent = 0,
  }) =>
      Row(
        children: [
          if (indent > 0) SizedBox(width: indent),
          Checkbox(
            value: value,
            onChanged: onChanged,
            activeColor: _kTodoAccent,
            side: const BorderSide(color: Colors.white38, width: 1.5),
          ),
          Expanded(
            child: Text(label, style: const TextStyle(color: _kTodoText)),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kTodoCard,
      titleTextStyle: _kTodoDialogTitle,
      title: const Text('Set Reminder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _check(
            value: _remindSelf,
            label: 'Remind me',
            onChanged: (v) => setState(() => _remindSelf = v ?? true),
          ),
          _check(
            value: _remindOther,
            label: 'Notify',
            onChanged: (v) => setState(() {
              _remindOther = v ?? false;
              if (!_remindOther) _addToList = false;
            }),
          ),
          if (_remindOther)
            _check(
              value: _addToList,
              label: 'Add to notify task list',
              indent: 32,
              onChanged: (v) => setState(() => _addToList = v ?? false),
            ),
          const Divider(color: _kTodoDivider, height: 20),
          const Row(
            children: [
              Icon(Icons.repeat, size: 18, color: _kTodoAccentLight),
              SizedBox(width: 10),
              Text('Repeat', style: TextStyle(color: _kTodoText)),
            ],
          ),
          DropdownButton<Recurrence>(
            value: _recurrence,
            isExpanded: true,
            dropdownColor: _kTodoCard,
            style: const TextStyle(color: _kTodoText),
            iconEnabledColor: _kTodoAccentLight,
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
          style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ReminderChoice(
              remindSelf: _remindSelf,
              remindOther: _remindOther,
              addToList: _addToList,
              recurrence: _recurrence,
            ),
          ),
          style: FilledButton.styleFrom(backgroundColor: _kTodoAccentDeep),
          child: const Text('Set'),
        ),
      ],
    );
  }
}
