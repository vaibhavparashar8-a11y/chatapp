part of '../calendar_screen.dart';

// ── Selected-day timeline ────────────────────────────────────────────────────
// A day view in the shape of the clock rather than a flat list: a 24-hour
// ruler with every reminder drawn at its own time, a live "now" line, and an
// auto-scroll that lands on the current hour. The whole day is therefore
// legible at a glance and a reminder's position — not just its label — carries
// the time. Apart from the scroll offset it holds no app state: every mutation
// routes back to _CalendarScreenState through callbacks.

/// Pixels per hour on the ruler. 64 leaves room for a two-line card inside an
/// hour slot without the day becoming an endless scroll.
const double _kHourHeight = 64;

/// Width of the hour-label gutter down the left edge.
const double _kGutter = 52;

/// Height of a reminder card. Tasks have no duration (see [Task]) — every card
/// is the same size and only its vertical position means anything.
const double _kCardHeight = 56;

/// Vertical offset of [at] on the ruler.
double _topOf(DateTime at) => (at.hour * 60 + at.minute) * _kHourHeight / 60;

String _hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// One reminder placed on the ruler: where it sits, and which of [lanes]
/// side-by-side columns it occupies.
class _Placed {
  final Task task;
  final DateTime at;
  final int lane;
  final int lanes;

  const _Placed(this.task, this.at, this.lane, this.lanes);

  double get top => _topOf(at);
}

/// Place [tasks] (already sorted earliest-first, all occurring on [day]) on the
/// ruler, splitting reminders whose cards would overlap into side-by-side
/// lanes so none is hidden behind another.
///
/// Cards are grouped into clusters of chained overlaps; a lane is reused as
/// soon as its previous card has ended, so two reminders an hour apart share a
/// full-width lane even when a third one between them forced a split.
List<_Placed> _layoutDay(List<Task> tasks, DateTime day) {
  final times = [for (final t in tasks) t.occurrenceOn(day)!];
  final out = <_Placed>[];
  var i = 0;
  while (i < tasks.length) {
    var clusterEnd = _topOf(times[i]) + _kCardHeight;
    var j = i + 1;
    while (j < tasks.length && _topOf(times[j]) < clusterEnd) {
      clusterEnd = math.max(clusterEnd, _topOf(times[j]) + _kCardHeight);
      j++;
    }
    final laneEnds = <double>[];
    final lanes = <int>[];
    for (var k = i; k < j; k++) {
      final top = _topOf(times[k]);
      var lane = laneEnds.indexWhere((end) => end <= top);
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(0);
      }
      laneEnds[lane] = top + _kCardHeight;
      lanes.add(lane);
    }
    for (var k = i; k < j; k++) {
      out.add(_Placed(tasks[k], times[k], lanes[k - i], laneEnds.length));
    }
    i = j;
  }
  return out;
}

class _DayTimeline extends StatefulWidget {
  final DateTime day;

  /// The day's reminders, earliest first.
  final List<Task> tasks;

  final void Function(Task task, bool done) onToggleDone;
  final ValueChanged<Task> onEdit;
  final ValueChanged<Task> onDelete;

  const _DayTimeline({
    super.key,
    required this.day,
    required this.tasks,
    required this.onToggleDone,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<_DayTimeline> {
  final _scroll = ScrollController();

  /// Drives the "now" line. A minute is as precise as the ruler can show.
  Timer? _tick;
  DateTime _now = DateTime.now();

  bool get _isToday =>
      widget.day.year == _now.year &&
      widget.day.month == _now.month &&
      widget.day.day == _now.day;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    // The scroll view has no clients until it is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAnchor());
  }

  // Selecting another day remounts this widget (the screen keys it on the
  // selected day), so the anchor is recomputed there — no didUpdateWidget.

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Land on the part of the day that matters: the current time for today,
  /// otherwise the first reminder, otherwise the morning. Anchored a third of
  /// the way down so what is coming next is on screen, not at the very edge.
  void _scrollToAnchor() {
    if (!mounted || !_scroll.hasClients) return;
    final double anchor;
    if (_isToday) {
      anchor = _topOf(_now);
    } else if (widget.tasks.isNotEmpty) {
      anchor = _topOf(widget.tasks.first.occurrenceOn(widget.day)!);
    } else {
      anchor = 8 * _kHourHeight;
    }
    final target = (anchor - _scroll.position.viewportDimension / 3)
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final placed = _layoutDay(widget.tasks, widget.day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${weekdayAbbrev(widget.day.weekday)} ${widget.day.day} '
                  '${monthYearLabel(widget.day)}'
                  '  ·  ${widget.tasks.length} reminder'
                  '${widget.tasks.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: kAppTextDim,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.tasks.isEmpty)
                const Text('Nothing on this day',
                    style: TextStyle(color: kAppTextFaint, fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Cards live to the right of the gutter, with a little air on
              // the right edge.
              final laneArea = constraints.maxWidth - _kGutter - 12;
              return SingleChildScrollView(
                controller: _scroll,
                child: SizedBox(
                  height: 24 * _kHourHeight + 88, // + room under the FAB
                  child: Stack(
                    children: [
                      // The ruler and the now line are decoration: they span
                      // the full width and would otherwise swallow taps meant
                      // for the cards they cross.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Stack(
                            children: [
                              for (var h = 0; h < 24; h++) _hourLine(h),
                              if (_isToday) _nowLine(),
                            ],
                          ),
                        ),
                      ),
                      for (final p in placed) _card(p, laneArea),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _hourLine(int hour) => Positioned(
        top: hour * _kHourHeight,
        left: 0,
        right: 0,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: _kGutter,
              // Nudged up so the label reads as sitting *on* the line.
              child: Transform.translate(
                offset: const Offset(0, -6),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '${hour.toString().padLeft(2, '0')}:00',
                    textAlign: TextAlign.right,
                    style: const TextStyle(color: kAppTextFaint, fontSize: 10),
                  ),
                ),
              ),
            ),
            const Expanded(
              child: SizedBox(height: 1, child: ColoredBox(color: kAppDivider)),
            ),
          ],
        ),
      );

  /// The current-time marker — the one thing on the ruler that moves.
  Widget _nowLine() => Positioned(
        top: _topOf(_now) - 4,
        left: _kGutter - 8,
        right: 0,
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  color: kAppNow, shape: BoxShape.circle),
            ),
            const Expanded(
              child: SizedBox(height: 2, child: ColoredBox(color: kAppNow)),
            ),
          ],
        ),
      );

  Widget _card(_Placed p, double laneArea) {
    final laneWidth = laneArea / p.lanes;
    return Positioned(
      top: p.top,
      height: _kCardHeight,
      left: _kGutter + p.lane * laneWidth,
      width: laneWidth - 4,
      child: _TimelineCard(
        task: p.task,
        at: p.at,
        onToggleDone: (done) => widget.onToggleDone(p.task, done),
        onEdit: () => widget.onEdit(p.task),
        onDelete: () => widget.onDelete(p.task),
      ),
    );
  }
}

/// A single reminder on the ruler. Swipe-left deletes, tap edits — the same
/// gestures as the todo screen's tiles.
class _TimelineCard extends StatelessWidget {
  final Task task;
  final DateTime at;
  final ValueChanged<bool> onToggleDone;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TimelineCard({
    required this.task,
    required this.at,
    required this.onToggleDone,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final mine = task.isMine(mySenderId);
    // The stripe is the only "whose is this" cue, so it stays visible even for
    // completed tasks — matching the Mine/Theirs tick-box colours.
    final accent = mine ? kAppAccentLight : kAppEmerald;

    return Dismissible(
      key: Key('cal_${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
            color: Colors.red.shade400,
            borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 14),
        child: const Icon(Icons.delete_rounded, size: 18, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(),
      child: Material(
        color: kAppCard,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 4, child: ColoredBox(color: accent)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: task.done,
                          onChanged: (v) => onToggleDone(v ?? false),
                          activeColor: kAppAccent,
                          shape: const CircleBorder(),
                          side: BorderSide(
                              color: task.done ? kAppAccent : Colors.white24,
                              width: 1.5),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: task.done ? kAppTextFaint : kAppText,
                                decoration: task.done
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 2),
                            _meta(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta() {
    final mine = task.isMine(mySenderId);
    return Row(children: [
      Text(_hhmm(at),
          style: const TextStyle(fontSize: 11, color: kAppAccentLight)),
      if (task.recurrence != Recurrence.none) ...[
        const SizedBox(width: 5),
        const Icon(Icons.repeat, size: 10, color: kAppAccentLight),
        const SizedBox(width: 2),
        Flexible(
          child: Text(
            task.recurrence.shortLabel(at),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: kAppAccentLight),
          ),
        ),
      ],
      if (!mine) ...[
        const SizedBox(width: 5),
        const Text('· shared',
            style: TextStyle(fontSize: 11, color: kAppEmerald)),
      ],
      if (!task.remindsMe) ...[
        const SizedBox(width: 5),
        const Icon(Icons.notifications_off_outlined,
            size: 10, color: kAppTextDim),
      ],
    ]);
  }
}
