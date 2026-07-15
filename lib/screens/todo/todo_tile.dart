part of '../todo_screen.dart';

// ── Task tile ────────────────────────────────────────────────────────────────
// A single task card: circular checkbox, title + reminder/sub-task meta, the
// reminder button, and an expandable sub-task section. All mutations are routed
// back to _TodoScreenState through callbacks so this widget stays state-free.

class _TodoTile extends StatelessWidget {
  final _Todo todo;
  final bool isExpanded;

  /// Controller for this task's "add sub-task" field, owned by the screen.
  final TextEditingController subCtrl;

  final VoidCallback onExpandToggle;
  final VoidCallback onEdit;
  final VoidCallback onSetReminder;
  final VoidCallback onDelete;
  final ValueChanged<bool?> onToggleDone;
  final void Function(_SubTodo sub, bool? val) onToggleSubtask;
  final ValueChanged<String> onDeleteSubtask;
  final VoidCallback onAddSubtask;

  const _TodoTile({
    required this.todo,
    required this.isExpanded,
    required this.subCtrl,
    required this.onExpandToggle,
    required this.onEdit,
    required this.onSetReminder,
    required this.onDelete,
    required this.onToggleDone,
    required this.onToggleSubtask,
    required this.onDeleteSubtask,
    required this.onAddSubtask,
  });

  @override
  Widget build(BuildContext context) {
    final hasReminder = todo.dueDate != null;
    final isOverdue =
        hasReminder && todo.dueDate!.isBefore(DateTime.now()) && !todo.done;

    Color accent;
    if (todo.done) {
      accent = Colors.white24;
    } else if (isOverdue) {
      accent = Colors.red.shade400;
    } else if (hasReminder) {
      accent = _kTodoAccent;
    } else {
      accent = _kTodoAppBar2;
    }

    return Dismissible(
      key: Key(todo.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.red.shade400,
            borderRadius: BorderRadius.circular(14)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _kTodoCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left accent stripe
                Container(width: 4, color: accent),
                // Card content
                Expanded(
                  child: Column(
                    children: [
                      // Main row — tap expands, checkbox toggles done
                      Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: onExpandToggle,
                          onLongPress: onEdit,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Circular checkbox
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                    value: todo.done,
                                    onChanged: onToggleDone,
                                    activeColor: _kTodoAccent,
                                    shape: const CircleBorder(),
                                    side: BorderSide(
                                      color: todo.done
                                          ? _kTodoAccent
                                          : Colors.white24,
                                      width: 1.5,
                                    ),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Title + meta
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        todo.title,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          decoration: todo.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                          color: todo.done
                                              ? _kTodoTextFaint
                                              : _kTodoText,
                                        ),
                                      ),
                                      if (hasReminder) ...[
                                        const SizedBox(height: 3),
                                        Row(children: [
                                          Icon(Icons.schedule_rounded,
                                              size: 11,
                                              color: isOverdue
                                                  ? Colors.red.shade400
                                                  : _kTodoAccentLight),
                                          const SizedBox(width: 3),
                                          Text(
                                            formatDue(todo.dueDate!),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isOverdue
                                                  ? Colors.red.shade400
                                                  : _kTodoAccentLight,
                                              fontWeight: isOverdue
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                          if (todo.recurrence !=
                                              Recurrence.none) ...[
                                            const SizedBox(width: 6),
                                            const Icon(Icons.repeat,
                                                size: 10,
                                                color: _kTodoAccentLight),
                                            const SizedBox(width: 2),
                                            Text(
                                              todo.recurrence
                                                  .shortLabel(todo.dueDate!),
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: _kTodoAccentLight),
                                            ),
                                          ],
                                        ]),
                                      ],
                                      if (todo.subtasks.isNotEmpty) ...[
                                        const SizedBox(height: 5),
                                        Row(children: [
                                          SizedBox(
                                            width: 72,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value: todo.doneSubtasks /
                                                    todo.subtasks.length,
                                                backgroundColor:
                                                    Colors.white12,
                                                color: todo.doneSubtasks ==
                                                        todo.subtasks.length
                                                    ? _kTodoEmerald
                                                    : _kTodoAccentLight,
                                                minHeight: 3,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${todo.doneSubtasks}/${todo.subtasks.length}',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: _kTodoTextDim),
                                          ),
                                        ]),
                                      ],
                                    ],
                                  ),
                                ),
                                // Unified reminder button — opens Set Reminder dialog
                                IconButton(
                                  icon: Icon(
                                    hasReminder
                                        ? Icons.alarm_on_rounded
                                        : Icons.add_alarm_rounded,
                                    size: 19,
                                    color: isOverdue
                                        ? Colors.red.shade400
                                        : hasReminder
                                            ? _kTodoAccent
                                            : Colors.white38,
                                  ),
                                  onPressed: onSetReminder,
                                  padding: const EdgeInsets.all(6),
                                  constraints: const BoxConstraints(),
                                ),
                                const SizedBox(width: 2),
                                // Expand arrow
                                AnimatedRotation(
                                  turns: isExpanded ? 0.5 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.white38,
                                    size: 22,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Sub-tasks section (animated)
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        child: isExpanded
                            ? Column(
                                children: [
                                  const Divider(
                                      height: 1,
                                      color: _kTodoDivider,
                                      indent: 16),
                                  ...todo.subtasks.map(_subtaskRow),
                                  _subtaskInput(),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _subtaskRow(_SubTodo sub) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: sub.done,
              onChanged: (v) => onToggleSubtask(sub, v),
              activeColor: _kTodoAccent,
              shape: const CircleBorder(),
              side: const BorderSide(color: Colors.white24, width: 1.5),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sub.title,
              style: TextStyle(
                fontSize: 13,
                color: sub.done ? _kTodoTextFaint : _kTodoTextDim,
                decoration: sub.done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                size: 16, color: Colors.white38),
            onPressed: () => onDeleteSubtask(sub.id),
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _subtaskInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.add, size: 15, color: Colors.white38),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: subCtrl,
              style: const TextStyle(fontSize: 13, color: _kTodoText),
              cursorColor: _kTodoAccentLight,
              decoration: InputDecoration(
                hintText: 'Add sub-task...',
                hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35), fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onAddSubtask(),
            ),
          ),
          GestureDetector(
            onTap: onAddSubtask,
            child: const Icon(Icons.send_rounded,
                size: 17, color: _kTodoAccentLight),
          ),
        ],
      ),
    );
  }
}
