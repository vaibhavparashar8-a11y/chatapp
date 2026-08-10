import 'recurrence.dart';

/// A checklist item under a [Task].
class SubTask {
  final String id;
  String title;
  bool done;

  SubTask(this.id, this.title, {this.done = false});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'done': done};

  factory SubTask.fromJson(Map json) => SubTask(
        json['id'] as String,
        json['title'] as String,
        done: json['done'] as bool? ?? false,
      );
}

/// One item on the todo list.
///
/// Promoted out of `screens/todo/todo_models.dart`, where it was a private
/// `_Todo` inside a `part` file — so neither unit-testable nor reachable from
/// the services.
///
/// A task is a title plus (optionally) a single instant. There are deliberately
/// no start/end spans, durations or all-day flags: the calendar screen renders
/// these same reminders on a month grid rather than introducing an event type.
class Task {
  final String id;
  String title;
  bool done;

  /// When the reminder fires. Named `dueDate` in the v1 storage format.
  /// Null = no reminder set.
  DateTime? start;

  List<SubTask> subtasks;

  /// How the reminder repeats.
  Recurrence recurrence;

  /// Whether **this phone** rings for [start] — the "Remind me" tick box.
  ///
  /// False means the time is still the task's time (so it is drawn on the
  /// calendar and shown on the tile) but no local alarm is armed for it: the
  /// task was set up only to notify the other person. Before this field
  /// existed, un-ticking "Remind me" cleared [start] outright, which made a
  /// reminder you set *for them* invisible on your own calendar.
  bool remindsMe;

  /// Which role created this task — `'A'` or `'B'`. Set from `mySenderId` for
  /// tasks made on this phone, and from the reminder doc's `createdBy` for
  /// shared tasks that arrived from the other phone. Drives the calendar's
  /// Mine/Theirs filter; null on tasks stored before this field existed, which
  /// counts as "mine" — only this phone could have written them.
  String? createdBy;

  /// Firestore reminder-doc ID when this task is shared with the other
  /// person ("Add to their task list") — edits/deletes sync via that doc.
  String? sharedId;

  /// Firestore reminder-doc ID for a reminder stored in Firestore but NOT
  /// mirrored across devices — a "Remind me" self reminder, or a "Remind them"
  /// reminder not added to their list. Kept separate from [sharedId] so the
  /// shared-task mirror never treats these as deleted-remotely.
  String? reminderDocId;

  Task(
    this.id,
    this.title, {
    this.done = false,
    this.start,
    List<SubTask>? subtasks,
    this.createdBy,
    this.sharedId,
    this.reminderDocId,
    this.recurrence = Recurrence.none,
    this.remindsMe = true,
  }) : subtasks = subtasks ?? [];

  /// The Firestore reminder doc backing this task, if any (mirrored or not).
  String? get backingDocId => sharedId ?? reminderDocId;

  int get doneSubtasks => subtasks.where((s) => s.done).length;

  /// True when this task has a reminder time at all.
  bool get hasReminder => start != null;

  /// True when this task was created on this device (role [me]). Tasks stored
  /// before `createdBy` existed count as mine.
  bool isMine(String me) => createdBy == null || createdBy == me;

  /// True when this reminder concerns the **other** person — either they made
  /// it, or [me] made it *for* them.
  ///
  /// Deliberately not the negation of [isMine]. A reminder you set for the
  /// other person is both: it may ring on your phone (so it belongs under
  /// "Mine") **and** it lives on their list (so it belongs under "Theirs").
  /// Filing it only by its creator meant "Drink water", set by A for B, was
  /// invisible whenever A looked at Theirs — which is where you would go to
  /// check what you had set for them.
  ///
  /// Three ways a task qualifies:
  ///  * they created it (it arrived from their phone);
  ///  * [sharedId] is set — it was mirrored onto their task list;
  ///  * it does not ring here ([remindsMe] false) — the only reason to set a
  ///    time you are not reminded of is to remind them.
  bool involvesOther(String me) =>
      (createdBy != null && createdBy != me) || sharedId != null || !remindsMe;

  /// Whether this task's reminder falls on the calendar day [day].
  ///
  /// A one-shot occurs only on its own date; a repeating one occurs on every
  /// matching day from [start] onward. This is **display-only** expansion for
  /// the calendar grid — the actual alarms are owned by AlarmManager via
  /// `NotificationService`, which repeats them natively. Nothing here schedules
  /// anything, so the two can't drift into disagreement about when a reminder
  /// fires; they only agree on which days to *draw*.
  bool occursOn(DateTime day) {
    final s = start;
    if (s == null) return false;
    final target = DateTime(day.year, day.month, day.day);
    final first = DateTime(s.year, s.month, s.day);
    if (target.isBefore(first)) return false; // never before it was set
    switch (recurrence) {
      case Recurrence.none:
        return target == first;
      case Recurrence.daily:
        return true;
      case Recurrence.weekly:
        return target.weekday == first.weekday;
      case Recurrence.weekdays:
      case Recurrence.weekends:
        return recurrence.fireDays.contains(target.weekday);
    }
  }

  /// This task's reminder time on [day] — the [start] time-of-day placed on
  /// that date. Null when it doesn't occur then.
  DateTime? occurrenceOn(DateTime day) {
    if (!occursOn(day)) return null;
    final s = start!;
    return DateTime(day.year, day.month, day.day, s.hour, s.minute);
  }

  // ── Storage (SharedPreferences `todos_v2`) ─────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'done': done,
        if (createdBy != null) 'createdBy': createdBy,
        if (sharedId != null) 'sharedId': sharedId,
        if (reminderDocId != null) 'reminderDocId': reminderDocId,
        if (start != null) 'start': start!.toIso8601String(),
        if (recurrence != Recurrence.none) 'recurrence': recurrence.storage,
        // Only written when off — every task stored before this field existed
        // was one this phone rang for.
        if (!remindsMe) 'remindsMe': false,
        'subtasks': subtasks.map((s) => s.toJson()).toList(),
      };

  /// Read a task from either storage format.
  ///
  /// The v1 key `dueDate` is still accepted so a list written by an older build
  /// — or by a background isolate that has not been updated yet — is never
  /// lost. Legacy shared copies created on the recipient side carry the doc ID
  /// inside their local ID (`reminder_<docId>`) and get their [sharedId]
  /// backfilled from it.
  factory Task.fromJson(Map json) {
    final id = json['id'] as String;
    final startRaw = (json['start'] ?? json['dueDate']) as String?;
    return Task(
      id,
      json['title'] as String,
      done: json['done'] as bool? ?? false,
      start: startRaw != null ? DateTime.tryParse(startRaw) : null,
      subtasks: (json['subtasks'] as List? ?? [])
          .map((s) => SubTask.fromJson(s as Map))
          .toList(),
      createdBy: json['createdBy'] as String?,
      sharedId: json['sharedId'] as String? ??
          (id.startsWith('reminder_')
              ? id.substring('reminder_'.length)
              : null),
      reminderDocId: json['reminderDocId'] as String?,
      recurrence: Recurrence.fromStorage(json['recurrence'] as String?),
      remindsMe: json['remindsMe'] as bool? ?? true,
    );
  }
}
