part of '../calendar_screen.dart';

// ── Month grid ───────────────────────────────────────────────────────────────
// A plain 7-column month, Monday-first. Each cell shows the day number and up
// to three dots for the reminders falling on it. State-free: the screen passes
// the count for each day and receives taps back.

/// Mine / Theirs tick boxes. Unticking the last one is refused — an empty
/// calendar with no explanation is worse than a filter that won't fully clear.
class _OwnerFilter extends StatelessWidget {
  final bool showMine;
  final bool showTheirs;
  final void Function(bool mine, bool theirs) onChanged;

  const _OwnerFilter({
    required this.showMine,
    required this.showTheirs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kAppHeaderBar,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          _box(
            label: 'Mine',
            value: showMine,
            colour: kAppAccentLight,
            // Refuse to clear the last one.
            onTap: () => onChanged(showTheirs ? !showMine : true, showTheirs),
          ),
          _box(
            label: 'Theirs',
            value: showTheirs,
            colour: kAppEmerald,
            onTap: () => onChanged(showMine, showMine ? !showTheirs : true),
          ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text('shared only',
                style: TextStyle(color: kAppTextFaint, fontSize: 10)),
          ),
        ],
      ),
    );
  }

  Widget _box({
    required String label,
    required bool value,
    required Color colour,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: value,
                  onChanged: (_) => onTap(),
                  activeColor: colour,
                  side: const BorderSide(color: Colors.white38, width: 1.5),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: value ? kAppText : kAppTextFaint, fontSize: 12)),
            ],
          ),
        ),
      );
}

class _MonthGrid extends StatelessWidget {
  /// First day of the month being drawn.
  final DateTime month;
  final DateTime selected;

  /// How many reminders fall on a given day — drives the dots.
  final int Function(DateTime day) countFor;
  final ValueChanged<DateTime> onSelect;

  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.countFor,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cells = monthCells(month);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              for (var wd = 1; wd <= 7; wd++)
                Expanded(
                  child: Center(
                    child: Text(
                      weekdayAbbrev(wd).substring(0, 1),
                      style: const TextStyle(
                          color: kAppTextFaint,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          for (var row = 0; row < cells.length ~/ 7; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(child: _cell(cells[row * 7 + col])),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(DateTime? day) {
    if (day == null) return const SizedBox(height: 44);

    final isSelected = _sameDay(day, selected);
    final isToday = _sameDay(day, DateTime.now());
    final count = countFor(day);

    return InkWell(
      onTap: () => onSelect(day),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 44,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: isSelected ? kAppAccentDeep : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isToday && !isSelected
              ? Border.all(color: kAppAccentLight, width: 1)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 13,
                color: isSelected ? Colors.white : kAppTextDim,
                fontWeight:
                    isToday || isSelected ? FontWeight.w700 : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 5,
              child: count == 0
                  ? null
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Three dots max, so a busy day doesn't overflow.
                        for (var i = 0; i < (count > 3 ? 3 : count); i++)
                          Container(
                            width: 4,
                            height: 4,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : kAppAccentLight,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
