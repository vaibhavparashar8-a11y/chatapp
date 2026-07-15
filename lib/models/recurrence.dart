/// How a reminder repeats. `none` is a one-shot reminder (the historical
/// behaviour); the rest map to native repeating local notifications.
///
/// The day/time always come from the task's picked due date — e.g. `weekly`
/// repeats on that date's weekday, `daily` at that time each day.
enum Recurrence {
  none,
  daily,
  weekly,
  weekdays, // Mon–Fri
  weekends; // Sat–Sun

  /// Full label for the Repeat picker.
  String get label {
    switch (this) {
      case Recurrence.none:
        return 'Does not repeat';
      case Recurrence.daily:
        return 'Every day';
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
