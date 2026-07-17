part of '../todo_screen.dart';

// ── Small presentational widgets ────────────────────────────────────────────
// Pure, state-free pieces of the todo screen. State lives in _TodoScreenState;
// these receive data + callbacks so the screen stays thin.

/// The pending/done counters shown under the app bar.
class _HeaderStats extends StatelessWidget {
  final int pending;
  final int done;
  const _HeaderStats({required this.pending, required this.done});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kTodoHeaderBar,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.pending_actions_rounded,
              size: 13, color: _kTodoAccentLight),
          const SizedBox(width: 4),
          Text('$pending pending',
              style: const TextStyle(color: _kTodoAccentLight, fontSize: 12)),
          if (done > 0) ...[
            const SizedBox(width: 14),
            const Icon(Icons.check_circle_outline,
                size: 13, color: _kTodoAccentLight),
            const SizedBox(width: 4),
            Text('$done done',
                style: const TextStyle(color: _kTodoAccentLight, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// Shown when there are no tasks at all.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(Icons.checklist_rounded, size: 72, color: _kTodoAccent),
          SizedBox(height: 16),
          Text('No tasks yet',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: _kTodoTextDim)),
          SizedBox(height: 6),
          Text('Add a task below to get started',
              style: TextStyle(fontSize: 13, color: _kTodoTextFaint)),
        ],
      ),
    );
  }
}

/// Shown when a search yields no matching tasks.
class _NoResults extends StatelessWidget {
  final String query;
  const _NoResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          const Icon(Icons.search_off_rounded, size: 72, color: _kTodoAccent),
          const SizedBox(height: 16),
          const Text('No matching tasks',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: _kTodoTextDim)),
          const SizedBox(height: 6),
          Text('No tasks match "$query"',
              style: const TextStyle(fontSize: 13, color: _kTodoTextFaint)),
        ],
      ),
    );
  }
}

/// A "COMPLETED (n)" style divider heading between task groups.
class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  const _SectionHeader({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Text(
            '${label.toUpperCase()} ($count)',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _kTodoAccentLight,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: _kTodoDivider, height: 1)),
        ],
      ),
    );
  }
}

/// Bottom "Add a task…" bar. Typing "flutter" opens the chat (via [onChanged]);
/// submit/FAB add the task (via [onSubmit]).
class _TaskInputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  const _TaskInputBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, MediaQuery.of(context).padding.bottom + 10),
      decoration: const BoxDecoration(
        color: _kTodoHeaderBar,
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.done,
              style: TextStyle(
                  fontSize: 15, color: RemoteConfigService.todoInputTextColor),
              onChanged: onChanged,
              onSubmitted: (_) => onSubmit(),
              decoration: InputDecoration(
                hintText: 'Add a task...',
                hintStyle:
                    TextStyle(color: Colors.white.withValues(alpha: 0.35)),
                filled: true,
                fillColor: _kTodoField,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FloatingActionButton(
            onPressed: onSubmit,
            backgroundColor: _kTodoAccentDeep,
            foregroundColor: Colors.white,
            elevation: 2,
            mini: true,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

/// Rename dialog — owns its TextEditingController so it is disposed with the
/// route (disposing in the caller crashes the still-animating dialog exit).
class _EditTaskDialog extends StatefulWidget {
  final String initial;
  final String title;
  final String hint;
  const _EditTaskDialog({
    required this.initial,
    this.title = 'Edit Task',
    this.hint = 'Task title',
  });

  @override
  State<_EditTaskDialog> createState() => _EditTaskDialogState();
}

class _EditTaskDialogState extends State<_EditTaskDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kTodoCard,
      titleTextStyle: _kTodoDialogTitle,
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        style: const TextStyle(color: _kTodoText),
        cursorColor: _kTodoAccentLight,
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
          enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: _kTodoDivider)),
          focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: _kTodoAccentLight)),
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          style: FilledButton.styleFrom(backgroundColor: _kTodoAccentDeep),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
