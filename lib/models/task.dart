import 'recurrence_rule.dart';

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
/// Promoted out of `screens/todo/todo_models.dart` (where it was a private
/// `_Todo` inside a `part` file, so neither unit-testable nor reusable) and
/// widened with the fields calendar views need: [end], [allDay] and [alerts],
/// plus a full [RecurrenceRule] in place of the five-value `Recurrence` enum.
///
/// **The widened fields round-trip but are not yet acted on.** A task with an
/// [end] renders and fires exactly like today's point-in-time reminder, and
/// [alerts] are stored but not scheduled — lead-time notifications and the
/// calendar views come next. The schema lands first so the stored-format
/// migration only ever happens once.
class Task {
  final String id;
  String title;
  bool done;

  /// When the task starts — the moment its reminder fires. Named `dueDate` in
  /// the v1 storage format. Null = no reminder set.
  DateTime? start;

  /// When the task ends. Null = a point in time rather than a span, which is
  /// every task today.
  DateTime? end;

  /// Occupies whole days rather than a time range; [start]'s time component is
  /// then not meaningful.
  bool allDay;

  /// How long before [start] to notify, e.g. `Duration(minutes: 10)`. Empty =
  /// notify at [start], today's behaviour. Stored as whole minutes.
  List<Duration> alerts;

  List<SubTask> subtasks;

  /// How the reminder repeats.
  RecurrenceRule recurrence;

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
    this.end,
    this.allDay = false,
    List<Duration>? alerts,
    List<SubTask>? subtasks,
    this.sharedId,
    this.reminderDocId,
    this.recurrence = RecurrenceRule.none,
  })  : alerts = alerts ?? [],
        subtasks = subtasks ?? [];

  /// The Firestore reminder doc backing this task, if any (mirrored or not).
  String? get backingDocId => sharedId ?? reminderDocId;

  int get doneSubtasks => subtasks.where((s) => s.done).length;

  /// True when this task has a reminder time at all.
  bool get hasReminder => start != null;

  /// Duration of the task, or null when it is a point in time.
  Duration? get duration =>
      end == null || start == null ? null : end!.difference(start!);

  // ── Storage (SharedPreferences `todos_v2`) ─────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'done': done,
        if (sharedId != null) 'sharedId': sharedId,
        if (reminderDocId != null) 'reminderDocId': reminderDocId,
        if (start != null) 'start': start!.toIso8601String(),
        if (end != null) 'end': end!.toIso8601String(),
        if (allDay) 'allDay': true,
        if (alerts.isNotEmpty)
          'alerts': alerts.map((d) => d.inMinutes).toList(),
        if (recurrence.storage != null) 'rrule': recurrence.storage,
        'subtasks': subtasks.map((s) => s.toJson()).toList(),
      };

  /// Read a task from either storage format.
  ///
  /// v1 keys (`dueDate`, `recurrence` as a plain enum name) are still accepted
  /// so a list written by an older build — or by a background isolate that has
  /// not been updated yet — is never lost. Legacy shared copies created on the
  /// recipient side carry the doc ID inside their local ID (`reminder_<docId>`)
  /// and get their [sharedId] backfilled from it.
  factory Task.fromJson(Map json) {
    final id = json['id'] as String;
    final startRaw = (json['start'] ?? json['dueDate']) as String?;
    final rruleRaw = (json['rrule'] ?? json['recurrence']) as String?;
    return Task(
      id,
      json['title'] as String,
      done: json['done'] as bool? ?? false,
      start: startRaw != null ? DateTime.tryParse(startRaw) : null,
      end: json['end'] != null ? DateTime.tryParse(json['end'] as String) : null,
      allDay: json['allDay'] as bool? ?? false,
      alerts: (json['alerts'] as List?)
          ?.map((m) => Duration(minutes: (m as num).toInt()))
          .toList(),
      subtasks: (json['subtasks'] as List? ?? [])
          .map((s) => SubTask.fromJson(s as Map))
          .toList(),
      sharedId: json['sharedId'] as String? ??
          (id.startsWith('reminder_')
              ? id.substring('reminder_'.length)
              : null),
      reminderDocId: json['reminderDocId'] as String?,
      recurrence: RecurrenceRule.fromStorage(rruleRaw),
    );
  }
}
