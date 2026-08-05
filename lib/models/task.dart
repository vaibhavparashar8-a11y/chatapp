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
  }) : subtasks = subtasks ?? [];

  /// The Firestore reminder doc backing this task, if any (mirrored or not).
  String? get backingDocId => sharedId ?? reminderDocId;

  int get doneSubtasks => subtasks.where((s) => s.done).length;

  /// True when this task has a reminder time at all.
  bool get hasReminder => start != null;

  /// True when this task was created on this device (role [me]). Tasks stored
  /// before `createdBy` existed count as mine.
  bool isMine(String me) => createdBy == null || createdBy == me;

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
    );
  }
}
