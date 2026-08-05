import 'recurrence.dart';

/// How often a rule repeats. Mirrors iCalendar's FREQ.
enum Freq { none, daily, weekly, monthly, yearly }

const _byDayCodes = ['', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// A calendar-style repeat rule — the replacement for the five-value
/// [Recurrence] enum, shaped after the subset of iCalendar RRULE that a
/// Google-Calendar-like repeat picker needs:
///
/// ```
/// FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20261231T090000
/// ```
///
/// Not every rule can be handed to Android's AlarmManager: it can repeat
/// daily and weekly-on-a-weekday natively, but has no notion of "every 3
/// days" or "every month". [toLegacy] returns null for those, and they need
/// occurrence expansion driven by the background worker — see the guide §5.
/// The repeat picker only offers natively-schedulable rules today, so nothing
/// currently produces a null.
class RecurrenceRule {
  final Freq freq;

  /// Every [interval] units of [freq] — 2 with [Freq.weekly] = fortnightly.
  /// Always >= 1.
  final int interval;

  /// Weekdays (`DateTime.monday`..`sunday` = 1..7) a weekly rule fires on.
  /// Empty means "the weekday of the task's start date", as in iCalendar.
  /// Always sorted, so equal rules compare equal.
  final List<int> byWeekday;

  /// Last moment an occurrence may fire. Mutually exclusive with [count] in
  /// practice; if both are set, whichever ends the series first wins.
  final DateTime? until;

  /// Stop after this many occurrences.
  final int? count;

  const RecurrenceRule._({
    required this.freq,
    required this.interval,
    required this.byWeekday,
    this.until,
    this.count,
  });

  factory RecurrenceRule({
    Freq freq = Freq.none,
    int interval = 1,
    List<int> byWeekday = const [],
    DateTime? until,
    int? count,
  }) {
    final days = byWeekday.where((d) => d >= 1 && d <= 7).toSet().toList()
      ..sort();
    return RecurrenceRule._(
      freq: freq,
      interval: interval < 1 ? 1 : interval,
      byWeekday: List.unmodifiable(days),
      until: until,
      count: count,
    );
  }

  /// Does not repeat.
  static const none =
      RecurrenceRule._(freq: Freq.none, interval: 1, byWeekday: []);

  bool get repeats => freq != Freq.none;

  // ── Legacy bridge ──────────────────────────────────────────────────────────
  // The five-value [Recurrence] enum is what NotificationService schedules
  // with, and what already sits in every stored todo and reminder doc. These
  // two convert both ways so nothing has to migrate at once.

  /// Build the equivalent rule for a legacy [Recurrence] value.
  factory RecurrenceRule.fromLegacy(Recurrence r) {
    switch (r) {
      case Recurrence.none:
        return none;
      case Recurrence.daily:
        return RecurrenceRule(freq: Freq.daily);
      case Recurrence.weekly:
        // No BYDAY — repeats on the start date's own weekday.
        return RecurrenceRule(freq: Freq.weekly);
      case Recurrence.weekdays:
        return RecurrenceRule(freq: Freq.weekly, byWeekday: const [1, 2, 3, 4, 5]);
      case Recurrence.weekends:
        return RecurrenceRule(freq: Freq.weekly, byWeekday: const [6, 7]);
    }
  }

  /// The [Recurrence] this rule is equivalent to, or **null** when it cannot
  /// be expressed as one — i.e. it needs occurrence expansion rather than a
  /// native repeating alarm. Callers must not silently treat null as
  /// "does not repeat": that is exactly the downgrade bug fixed in #96.
  Recurrence? toLegacy() {
    if (freq == Freq.none) return Recurrence.none;
    if (interval != 1 || until != null || count != null) return null;
    switch (freq) {
      case Freq.daily:
        return byWeekday.isEmpty ? Recurrence.daily : null;
      case Freq.weekly:
        if (byWeekday.isEmpty) return Recurrence.weekly;
        final days = byWeekday.join(',');
        if (days == '1,2,3,4,5') return Recurrence.weekdays;
        if (days == '6,7') return Recurrence.weekends;
        return null;
      case Freq.monthly:
      case Freq.yearly:
      case Freq.none:
        return null;
    }
  }

  /// True when this rule maps onto a native repeating alarm ([toLegacy] != null).
  bool get isNativelySchedulable => toLegacy() != null;

  // ── Storage ────────────────────────────────────────────────────────────────

  /// Serialize to an RRULE string. [none] serializes to null so a
  /// non-repeating task stores no field at all.
  String? get storage {
    if (freq == Freq.none) return null;
    final parts = <String>['FREQ=${freq.name.toUpperCase()}'];
    if (interval != 1) parts.add('INTERVAL=$interval');
    if (byWeekday.isNotEmpty) {
      parts.add('BYDAY=${byWeekday.map((d) => _byDayCodes[d]).join(',')}');
    }
    if (until != null) parts.add('UNTIL=${_fmtUntil(until!)}');
    if (count != null) parts.add('COUNT=$count');
    return parts.join(';');
  }

  /// Parse an RRULE string. Tolerates the legacy enum names ("daily",
  /// "weekdays", …) so stored todos and reminder docs written before this
  /// model read back correctly. Unknown input parses as [none] — matching
  /// [Recurrence.fromStorage]'s long-standing behaviour.
  static RecurrenceRule fromStorage(String? s) {
    if (s == null || s.isEmpty) return none;
    if (!s.contains('=')) return RecurrenceRule.fromLegacy(Recurrence.fromStorage(s));

    var freq = Freq.none;
    var interval = 1;
    var days = <int>[];
    DateTime? until;
    int? count;

    for (final part in s.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final key = part.substring(0, eq).toUpperCase();
      final value = part.substring(eq + 1);
      switch (key) {
        case 'FREQ':
          freq = Freq.values.firstWhere(
            (f) => f.name.toUpperCase() == value.toUpperCase(),
            orElse: () => Freq.none,
          );
        case 'INTERVAL':
          interval = int.tryParse(value) ?? 1;
        case 'BYDAY':
          days = value
              .split(',')
              .map((c) => _byDayCodes.indexOf(c.trim().toUpperCase()))
              .where((i) => i > 0)
              .toList();
        case 'UNTIL':
          until = _parseUntil(value);
        case 'COUNT':
          count = int.tryParse(value);
      }
    }
    if (freq == Freq.none) return none;
    return RecurrenceRule(
      freq: freq,
      interval: interval,
      byWeekday: days,
      until: until,
      count: count,
    );
  }

  /// `yyyymmddTHHMMSS`, local wall time (matching how task times are stored).
  static String _fmtUntil(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}T'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  static DateTime? _parseUntil(String s) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2}))?$')
        .firstMatch(s.trim());
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i) ?? '0');
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
  }

  // ── Labels ─────────────────────────────────────────────────────────────────

  /// Full label for the repeat picker.
  String get label {
    if (freq == Freq.none) return 'Does not repeat';
    final legacy = toLegacy();
    if (legacy != null && legacy != Recurrence.none) return legacy.label;
    final unit = switch (freq) {
      Freq.daily => interval == 1 ? 'day' : 'days',
      Freq.weekly => interval == 1 ? 'week' : 'weeks',
      Freq.monthly => interval == 1 ? 'month' : 'months',
      Freq.yearly => interval == 1 ? 'year' : 'years',
      Freq.none => '',
    };
    return interval == 1 ? 'Every $unit' : 'Every $interval $unit';
  }

  /// Compact label for the task tile. [day] names the weekday for a weekly
  /// rule with no BYDAY (e.g. "Every Mon").
  String shortLabel(DateTime day) {
    if (freq == Freq.none) return '';
    final legacy = toLegacy();
    if (legacy != null && legacy != Recurrence.none) return legacy.shortLabel(day);
    if (byWeekday.isNotEmpty) {
      return byWeekday.map((d) => weekdayAbbrev(d)).join(', ');
    }
    return label;
  }

  RecurrenceRule copyWith({
    Freq? freq,
    int? interval,
    List<int>? byWeekday,
    DateTime? until,
    int? count,
  }) =>
      RecurrenceRule(
        freq: freq ?? this.freq,
        interval: interval ?? this.interval,
        byWeekday: byWeekday ?? this.byWeekday,
        until: until ?? this.until,
        count: count ?? this.count,
      );

  @override
  bool operator ==(Object other) =>
      other is RecurrenceRule &&
      other.freq == freq &&
      other.interval == interval &&
      other.until == until &&
      other.count == count &&
      _sameDays(other.byWeekday, byWeekday);

  static bool _sameDays(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(freq, interval, until, count, Object.hashAll(byWeekday));

  @override
  String toString() => storage ?? 'none';
}
