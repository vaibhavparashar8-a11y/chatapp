part of '../calendar_screen.dart';

// ── Selected-day reminder list ───────────────────────────────────────────────
// The rows under the grid. State-free: every mutation is routed back to
// _CalendarScreenState through callbacks.

class _DayList extends StatelessWidget {
  final DateTime day;
  final List<Task> tasks;
  final void Function(Task task, bool done) onToggleDone;
  final ValueChanged<Task> onEdit;
  final ValueChanged<Task> onDelete;

  const _DayList({
    required this.day,
    required this.tasks,
    required this.onToggleDone,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            '${weekdayAbbrev(day.weekday)} ${day.day} ${monthYearLabel(day)}'
            '  ·  ${tasks.length} reminder${tasks.length == 1 ? '' : 's'}',
            style: const TextStyle(
                color: kAppTextDim, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? const Center(
                  child: Text('Nothing on this day',
                      style: TextStyle(color: kAppTextFaint, fontSize: 13)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: tasks.length,
                  itemBuilder: (_, i) => _row(tasks[i]),
                ),
        ),
      ],
    );
  }

  Widget _row(Task task) {
    final at = task.occurrenceOn(day)!;
    final mine = task.isMine(mySenderId);
    // The stripe is the only "whose is this" cue, so it stays visible even for
    // completed tasks — matching the Mine/Theirs tick-box colours.
    final accent = mine ? kAppAccentLight : kAppEmerald;

    return Dismissible(
      key: Key('cal_${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
            color: Colors.red.shade400,
            borderRadius: BorderRadius.circular(12)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(task),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: kAppCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: accent),
                Expanded(
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: () => onEdit(task),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: task.done,
                                onChanged: (v) => onToggleDone(task, v ?? false),
                                activeColor: kAppAccent,
                                shape: const CircleBorder(),
                                side: BorderSide(
                                    color: task.done
                                        ? kAppAccent
                                        : Colors.white24,
                                    width: 1.5),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    task.title,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: task.done
                                          ? kAppTextFaint
                                          : kAppText,
                                      decoration: task.done
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(children: [
                                    Text(
                                      _hhmm(at),
                                      style: const TextStyle(
                                          fontSize: 11, color: kAppAccentLight),
                                    ),
                                    if (task.recurrence != Recurrence.none) ...[
                                      const SizedBox(width: 6),
                                      const Icon(Icons.repeat,
                                          size: 10, color: kAppAccentLight),
                                      const SizedBox(width: 2),
                                      Text(
                                        task.recurrence.shortLabel(at),
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: kAppAccentLight),
                                      ),
                                    ],
                                    if (!mine) ...[
                                      const SizedBox(width: 6),
                                      const Text('· shared',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: kAppEmerald)),
                                    ],
                                  ]),
                                ],
                              ),
                            ),
                            const Icon(Icons.edit_rounded,
                                size: 15, color: Colors.white38),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}
