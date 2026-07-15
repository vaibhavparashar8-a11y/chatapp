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
      accent = Colors.grey.shade300;
    } else if (isOverdue) {
      accent = Colors.red.shade400;
    } else if (hasReminder) {
      accent = Colors.indigo.shade400;
    } else {
      accent = Colors.indigo.shade100;
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
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
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
                                    activeColor: Colors.indigo,
                                    shape: const CircleBorder(),
                                    side: BorderSide(
                                      color: todo.done
                                          ? Colors.indigo
                                          : Colors.grey.shade400,
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
                                              ? Colors.grey.shade400
                                              : Colors.black87,
                                        ),
                                      ),
                                      if (hasReminder) ...[
                                        const SizedBox(height: 3),
                                        Row(children: [
                                          Icon(Icons.schedule_rounded,
                                              size: 11,
                                              color: isOverdue
                                                  ? Colors.red.shade400
                                                  : Colors.indigo.shade300),
                                          const SizedBox(width: 3),
                                          Text(
                                            formatDue(todo.dueDate!),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isOverdue
                                                  ? Colors.red.shade400
                                                  : Colors.indigo.shade300,
                                              fontWeight: isOverdue
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                            ),
                                          ),
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
                                                    Colors.grey.shade200,
                                                color: todo.doneSubtasks ==
                                                        todo.subtasks.length
                                                    ? Colors.green.shade400
                                                    : Colors.indigo.shade300,
                                                minHeight: 3,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${todo.doneSubtasks}/${todo.subtasks.length}',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey.shade500),
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
                                            ? Colors.indigo.shade400
                                            : Colors.grey.shade400,
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
                                  child: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey.shade400,
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
                                  Divider(
                                      height: 1,
                                      color: Colors.grey.shade100,
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
              activeColor: Colors.indigo.shade300,
              shape: const CircleBorder(),
              side: BorderSide(color: Colors.grey.shade300, width: 1.5),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sub.title,
              style: TextStyle(
                fontSize: 13,
                color: sub.done ? Colors.grey.shade400 : Colors.black54,
                decoration: sub.done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded,
                size: 16, color: Colors.grey.shade300),
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
          Icon(Icons.add, size: 15, color: Colors.grey.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: subCtrl,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
              decoration: InputDecoration(
                hintText: 'Add sub-task...',
                hintStyle:
                    TextStyle(color: Colors.grey.shade400, fontSize: 13),
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
            child: Icon(Icons.send_rounded,
                size: 17, color: Colors.indigo.shade300),
          ),
        ],
      ),
    );
  }
}
