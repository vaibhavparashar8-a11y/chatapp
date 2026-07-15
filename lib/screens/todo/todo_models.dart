part of '../todo_screen.dart';

// ── Models ────────────────────────────────────────────────────────────────────

class _SubTodo {
  final String id;
  String title;
  bool done;
  _SubTodo(this.id, this.title, {this.done = false});
}

class _Todo {
  final String id;
  String title;
  bool done;
  DateTime? dueDate;
  List<_SubTodo> subtasks;

  /// Firestore reminder-doc ID when this task is shared with the other
  /// person ("Add to their task list") — edits/deletes sync via that doc.
  String? sharedId;

  /// Firestore reminder-doc ID for a reminder that is stored in Firestore but
  /// NOT mirrored across devices — i.e. a "Remind me" self reminder, or a
  /// "Remind them" reminder that was not added to their list. Used to keep the
  /// stored doc in sync (title/time) and to delete it when this task is
  /// deleted. Kept separate from [sharedId] so the shared-task mirror
  /// (applySharedSnapshot) never treats these as deleted-remotely.
  String? reminderDocId;

  _Todo(this.id, this.title,
      {this.done = false,
      this.dueDate,
      List<_SubTodo>? subtasks,
      this.sharedId,
      this.reminderDocId})
      : subtasks = subtasks ?? [];

  /// The Firestore reminder doc backing this task, if any (mirrored or not).
  String? get backingDocId => sharedId ?? reminderDocId;

  int get doneSubtasks => subtasks.where((s) => s.done).length;
}
