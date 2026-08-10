/// How a reminder repeats. `none` is a one-shot reminder (the historical
/// behaviour); the rest map to native repeating local notifications.
///
/// The day/time always come from the task's picked due date — e.g. `weekly`
/// repeats on that date's weekday, `daily` at that time each day.
enum Recurrence {
  none,
  daily,
  hourly, // every hour through the day
  every90m, // every 90 minutes through the day
  every2h, // every 2 hours through the day
  weekly,
  weekdays, // Mon–Fri
  weekends; // Sat–Sun

  /// Minutes between fires **within a day**; null for rules that fire at most
  /// once a day.
  ///
  /// An interval rule is not a new kind of alarm: it expands into one ordinary
  /// daily notification per slot (see [daySlotMinutes]), each repeating
  /// natively, so the OS still owns every repeat and they survive reboot and
  /// app-kill exactly like the others.
  int? get intervalMinutes {
    switch (this) {
      case Recurrence.hourly:
        return 60;
      case Recurrence.every90m:
        return 90;
      case Recurrence.every2h:
        return 120;
      default:
        return null;
    }
  }

  /// Last time of day an interval rule may fire, in minutes from midnight.
  /// Without a stop, "every 90 minutes" would wake you at 03:00.
  static const int dayEndMinutes = 22 * 60; // 22:00

  /// The times of day this rule fires, as minutes from midnight, given the
  /// reminder's picked [hour]/[minute].
  ///
  /// One entry for every non-interval rule. For an interval rule: the picked
  /// time, then every [intervalMinutes] until [dayEndMinutes] — so 08:00 with
  /// `every90m` gives 08:00, 09:30, 11:00 … 21:30. The picked time is always
  /// included even when it is already past the cutoff, so a reminder set for
  /// 23:00 still fires once rather than silently never.
  List<int> daySlotMinutes(int hour, int minute) {
    final start = hour * 60 + minute;
    final step = intervalMinutes;
    if (step == null) return [start];
    final out = <int>[start];
    for (var t = start + step; t <= dayEndMinutes; t += step) {
      out.add(t);
    }
    return out;
  }

  /// Full label for the Repeat picker.
  String get label {
    switch (this) {
      case Recurrence.none:
        return 'Does not repeat';
      case Recurrence.daily:
        return 'Every day';
      case Recurrence.hourly:
        return 'Every hour (until 10pm)';
      case Recurrence.every90m:
        return 'Every 90 minutes (until 10pm)';
      case Recurrence.every2h:
        return 'Every 2 hours (until 10pm)';
      case Recurrence.weekly:
        return 'Every week';
      case Recurrence.weekdays:
        return 'Weekdays (Mon–Fri)';
      case Recurrence.weekends:
        return 'Weekends (Sat–Sun)';
    }
  }

  /// Compact label for the task tile. [day] is the reminder's due date, used to
  /// name the weekday for [Recurrence.weekly] (e.g. "Every Mon").
  String shortLabel(DateTime day) {
    switch (this) {
      case Recurrence.none:
        return '';
      case Recurrence.daily:
        return 'Every day';
      case Recurrence.hourly:
        return 'Every 1h';
      case Recurrence.every90m:
        return 'Every 90m';
      case Recurrence.every2h:
        return 'Every 2h';
      case Recurrence.weekly:
        return 'Every ${weekdayAbbrev(day.weekday)}';
      case Recurrence.weekdays:
        return 'Weekdays';
      case Recurrence.weekends:
        return 'Weekends';
    }
  }

  /// The weekdays (DateTime.monday..sunday = 1..7) this recurrence fires on.
  /// Empty for [none]/[daily] (which aren't day-specific).
  List<int> get fireDays {
    switch (this) {
      case Recurrence.weekdays:
        return const [1, 2, 3, 4, 5];
      case Recurrence.weekends:
        return const [6, 7];
      default:
        return const [];
    }
  }

  /// Value persisted in SharedPreferences.
  String get storage => name;

  static Recurrence fromStorage(String? s) {
    if (s == null) return Recurrence.none;
    for (final r in Recurrence.values) {
      if (r.name == s) return r;
    }
    return Recurrence.none;
  }
}

const _weekdayAbbrev = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Mon".."Sun" for DateTime.weekday (1..7).
String weekdayAbbrev(int weekday) =>
    (weekday >= 1 && weekday <= 7) ? _weekdayAbbrev[weekday] : '';
