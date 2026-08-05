import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_screen.dart';
import 'calendar_screen.dart';
import '../services/device_service.dart';
import '../services/remote_config_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../services/call_log_service.dart';
import '../services/log_service.dart';
import '../services/digest_service.dart';
import '../services/task_store.dart';
import '../models/recurrence.dart';
import '../models/task.dart';
import '../theme/app_palette.dart';
import '../constants.dart' show mySenderId, todoRefreshNotifier;
import '../utils/time_utils.dart';

// Split into `part` files to keep this screen approachable (see CLAUDE.md
// file-size guideline). All presentational widgets live alongside;
// _TodoScreenState below owns the state and orchestration. The task model
// itself is NOT a part file — it lives in lib/models/task.dart so it can be
// unit-tested and reused by the services.
part 'todo/todo_theme.dart';
part 'todo/todo_widgets.dart';
part 'todo/todo_tile.dart';
part 'todo/todo_dialogs.dart';
part 'todo/todo_reminder_dialog.dart';
part 'todo/todo_reminders.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});
  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> with WidgetsBindingObserver {
  final _addCtrl = TextEditingController();
  final _addFocus = FocusNode();
  final _searchCtrl = TextEditingController();
  final Map<String, TextEditingController> _subCtrl = {};
  final Set<String> _expanded = {};
  List<Task> _todos = [];
  String _searchQuery = '';
  bool _searching = false;

  /// Delivery status of reminders this phone sent to the other person, keyed by
  /// reminder-doc id. `true` = their phone has received and armed it.
  Map<String, bool> _deliveryByDoc = {};
  StreamSubscription<Map<String, bool>>? _deliverySub;

  @override
  void initState() {
    super.initState();
    // Load, then re-arm any pending reminders the OS dropped on an APK update.
    unawaited(_loadTodos().then((_) {
      if (mounted) return _rearmReminders();
    }));
    // Watch delivery confirmations for reminders we sent to the other person.
    _deliverySub = ReminderService.outgoingDeliveryStream().listen((map) {
      if (mounted) setState(() => _deliveryByDoc = map);
    });
    // Home screen is always in the tree, so its resume fires whenever the app
    // returns to the foreground — sync recent calls then (throttled), so new
    // calls appear without a full app relaunch.
    WidgetsBinding.instance.addObserver(this);
    // Record that this device opened the todo app (mirrors chat's appLastOpened).
    unawaited(DeviceService.writeTodoOpened());
    todoRefreshNotifier.addListener(_onRemoteTaskArrived);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(CallLogService.sync());
      unawaited(DeviceService.writeTodoOpened());
    }
  }

  @override
  void dispose() {
    todoRefreshNotifier.removeListener(_onRemoteTaskArrived);
    WidgetsBinding.instance.removeObserver(this);
    _deliverySub?.cancel();
    _addCtrl.dispose();
    _addFocus.dispose();
    _searchCtrl.dispose();
    for (final c in _subCtrl.values) c.dispose();
    super.dispose();
  }

  void _onRemoteTaskArrived() => _loadTodos();

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _loadTodos() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      // TaskStore owns the key and the v1 → v2 format migration.
      var tasks = await TaskStore.load(prefs);
      if (tasks.isEmpty && prefs.getString(TaskStore.key) == null) {
        // Fresh install / cleared data: restore this device's Firestore backup
        // (role is reclaimed via ANDROID_ID) so reminders survive a reinstall.
        // The blob may be in either storage format — Task.fromJson reads both.
        final raw = await ReminderService.fetchTodoBackup();
        if (raw == null) return;
        tasks = TaskStore.decode(raw);
        await TaskStore.save(prefs, tasks); // persist so we don't refetch
      }
      if (!mounted) return;
      setState(() => _todos = tasks);
    } catch (e, st) {
      // Corrupt/unreadable todo JSON. Don't wipe it — the Firestore backup may
      // still restore it — but never fail silently: this used to leave the user
      // staring at an empty list with no clue why.
      LogService.e('todo', 'could not parse stored todos: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not load your tasks.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _saveTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final json = await TaskStore.save(prefs, _todos);
    // Mirror to Firestore (role-keyed) so these reminders survive a reinstall.
    unawaited(ReminderService.backupTodos(json)
        .catchError((e) => LogService.w('todo', 'todo backup failed: $e')));
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  /// Open the month view over these same reminders. Reloads on return, since
  /// the calendar can add, edit or delete tasks in the shared store.
  Future<void> _openCalendar() async {
    _addFocus.unfocus();
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const CalendarScreen()));
    if (mounted) await _loadTodos();
  }

  void _openChat() {
    _addCtrl.clear();
    _addFocus.unfocus();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ChatScreen()));
  }

  // ── Task creation ─────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final text = _addCtrl.text.trim();
    if (text.isEmpty) return;
    if (text.toLowerCase() == 'flutter') {
      _openChat();
      return;
    }

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    // Stamp the creator so the calendar's Mine/Theirs filter can place it.
    final todo = Task(id, text, createdBy: mySenderId);
    setState(() => _todos.insert(0, todo));
    _addCtrl.clear();
    await _saveTodos();

    if (!mounted) return;
    if (await _askSetReminder(text) && mounted) {
      await _setReminder(todo);
    }
  }

  /// Single entry point for all reminder actions on a task.
  /// Picks date/time first, then shows a dialog to choose who gets reminded.
  Future<void> _setReminder(Task todo) async {
    final start = await _pickDateTime(initial: todo.start);
    if (start == null || !mounted) return;

    final choice = await showDialog<_ReminderChoice>(
      context: context,
      builder: (_) => _SetReminderDialog(
        initialRecurrence: todo.recurrence,
        scheduledAt: start,
      ),
    );
    if (choice == null || !mounted) return;

    final remindSelf = choice.remindSelf;
    final remindOther = choice.remindOther;
    final recurrence = choice.recurrence;

    // The local alarm always follows this dialog — including when "Remind me"
    // is left unchecked, where the previous schedule must be CLEARED. Leaving
    // it armed meant a task re-timed with "Remind me" off still fired at its
    // old time, and the tile kept showing the old time too.
    final hadLocalReminder = todo.start != null;
    if (hadLocalReminder) {
      await NotificationService.cancelReminderGroup(todo.id.hashCode);
      final existingDoc = todo.backingDocId;
      if (existingDoc != null) {
        await NotificationService.cancelReminder(
            NotificationService.docNotifId(existingDoc));
      }
    }
    if (!mounted) return;
    setState(() {
      todo.start = remindSelf ? start : null;
      todo.recurrence = remindSelf ? recurrence : Recurrence.none;
    });
    await _saveTodos();

    if (remindSelf) {
      final ok = await _armLocalReminder(todo, start, recurrence);
      if (mounted) {
        final repeat =
            recurrence != Recurrence.none ? ' · ${recurrence.shortLabel(start)}' : '';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? 'Reminder set for ${formatDue(start)}$repeat'
              : 'Could not set reminder. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } else if (!remindOther && mounted) {
      // Neither box ticked: previously this fell through and did nothing at
      // all, with no feedback. Say what happened instead.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(hadLocalReminder
            ? 'Reminder cleared'
            : 'Nothing selected — tick "Remind me" or "Notify"'),
        behavior: SnackBarBehavior.floating,
      ));
    }

    await _persistReminderDoc(todo, start, choice);
  }

  // ── Sub-tasks ─────────────────────────────────────────────────────────────

  void _addSubtask(Task todo) {
    final ctrl = _subCtrl.putIfAbsent(todo.id, () => TextEditingController());
    final text = ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => todo.subtasks
        .add(SubTask(DateTime.now().microsecondsSinceEpoch.toString(), text)));
    ctrl.clear();
    unawaited(_saveTodos());
    _syncSubtasks(todo);
  }

  void _toggleSubtask(Task todo, SubTask sub, bool? val) {
    setState(() => sub.done = val ?? false);
    unawaited(_saveTodos());
    _syncSubtasks(todo);
  }

  void _deleteSubtask(Task todo, String subId) {
    setState(() => todo.subtasks.removeWhere((s) => s.id == subId));
    unawaited(_saveTodos());
    _syncSubtasks(todo);
  }

  /// Rename a sub-task via a small dialog; writes through for shared tasks.
  Future<void> _editSubtask(Task todo, SubTask sub) async {
    final newTitle = await showDialog<String>(
      context: context,
      builder: (_) => _EditTaskDialog(
        initial: sub.title,
        title: 'Edit sub-task',
        hint: 'Sub-task',
      ),
    );
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == sub.title || !mounted) {
      return;
    }
    setState(() => sub.title = trimmed);
    await _saveTodos();
    _syncSubtasks(todo);
  }

  /// Sub-task list serialized for Firestore / the shared reminder doc.
  List<Map<String, dynamic>> _subtaskPayload(Task todo) => todo.subtasks
      .map((s) => {'id': s.id, 'title': s.title, 'done': s.done})
      .toList();

  /// Push a mirrored shared task's sub-tasks to its reminder doc so the other
  /// device sees the change. Only `sharedId` tasks are mirrored — stored-only
  /// reminders (reminderDocId) aren't shown on the other phone, so skip them.
  void _syncSubtasks(Task todo) {
    final sid = todo.sharedId;
    if (sid == null) return;
    unawaited(ReminderService.updateSharedTask(sid,
            subtasks: _subtaskPayload(todo))
        .catchError((e) => LogService.w('todo', 'subtask sync failed: $e')));
  }

  // ── Task management ───────────────────────────────────────────────────────

  void _toggleDone(Task todo, bool? val) {
    setState(() => todo.done = val ?? false);
    unawaited(_saveTodos());
    if (todo.backingDocId != null) {
      // Offline edit — Firestore retries when back online, so this is not
      // user-facing, but log it rather than swallowing it entirely.
      unawaited(ReminderService.updateSharedTask(todo.backingDocId!,
              done: todo.done)
          .catchError((e) => LogService.w('todo', 'done sync failed: $e')));
    }
  }

  void _delete(String id) {
    final idx = _todos.indexWhere((t) => t.id == id);
    // Any Firestore reminder doc backing this task — mirrored (sharedId) or
    // stored-only (reminderDocId, i.e. self / remind-them). Deleting the task
    // deletes its doc so it never lingers in Firestore.
    final docId = idx != -1 ? _todos[idx].backingDocId : null;
    if (idx != -1 && _todos[idx].start != null) {
      // Group cancel in case this reminder was recurring (weekdays/weekends
      // schedule several notifications under derived ids).
      unawaited(NotificationService.cancelReminderGroup(id.hashCode));
      if (docId != null) {
        unawaited(
            NotificationService.cancelReminder(NotificationService.docNotifId(docId)));
      }
    }
    _subCtrl.remove(id)?.dispose();
    _expanded.remove(id);
    setState(() => _todos.removeWhere((t) => t.id == id));
    unawaited(_saveTodos());
    if (docId != null) {
      unawaited(ReminderService.deleteSharedTask(docId).catchError(
          (e) => LogService.w('todo', 'shared task delete failed: $e')));
    }
  }

  /// Long-press on a task tile — rename it. Shared tasks push the new title
  /// to Firestore so the other person's copy updates too.
  Future<void> _editTask(Task todo) async {
    final newTitle = await showDialog<String>(
      context: context,
      builder: (_) => _EditTaskDialog(initial: todo.title),
    );
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == todo.title || !mounted) {
      return;
    }
    setState(() => todo.title = trimmed);
    await _saveTodos();
    // Re-schedule so the pending notification carries the new title. Recurring
    // reminders reschedule even when the original due date has passed (future
    // occurrences still fire).
    if (todo.start != null &&
        !todo.done &&
        (todo.recurrence != Recurrence.none || todo.start!.isAfter(DateTime.now()))) {
      await NotificationService.cancelReminderGroup(todo.id.hashCode);
      await _armLocalReminder(todo, todo.start!, todo.recurrence);
    }
    if (todo.backingDocId != null) {
      unawaited(ReminderService.updateSharedTask(todo.backingDocId!,
              title: trimmed)
          .catchError((e) => LogService.w('todo', 'title sync failed: $e')));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  void _openSearch() {
    setState(() {
      _searching = true;
      _searchQuery = '';
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _searchQuery = '';
      _searchCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? _todos
        : _todos
            .where((t) =>
                t.title.toLowerCase().contains(query) ||
                t.subtasks.any((s) => s.title.toLowerCase().contains(query)))
            .toList();
    final pending = filtered.where((t) => !t.done).toList();
    final done = filtered.where((t) => t.done).toList();

    return Scaffold(
      backgroundColor: _kTodoBg,
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                cursorColor: _kTodoAccentLight,
                decoration: const InputDecoration(
                  hintText: 'Search tasks...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : GestureDetector(
                onDoubleTap: kDebugMode ? _showRoleResetDialog : null,
                child: const Text('My Tasks',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
              ),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_kTodoAppBar1, _kTodoAppBar2],
            ),
          ),
        ),
        actions: [
          if (_searching)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _closeSearch,
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.calendar_month_outlined),
              tooltip: 'Calendar',
              onPressed: _openCalendar,
            ),
            IconButton(
              icon: const Icon(Icons.notifications_active_outlined),
              tooltip: 'Daily summary',
              onPressed: _showDigestSettings,
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _openSearch,
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: _HeaderStats(pending: pending.length, done: done.length),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              children: [
                if (pending.isEmpty && done.isEmpty)
                  _searchQuery.isNotEmpty
                      ? _NoResults(query: _searchQuery)
                      : const _EmptyState()
                else ...[
                  ...pending.map(_tileFor),
                  if (done.isNotEmpty) ...[
                    _SectionHeader(label: 'Completed', count: done.length),
                    ...done.map(_tileFor),
                  ],
                ],
              ],
            ),
          ),
          _TaskInputBar(
            controller: _addCtrl,
            focusNode: _addFocus,
            onChanged: _onInputChanged,
            onSubmit: _submit,
          ),
        ],
      ),
    );
  }

  /// Build a task tile wired to this screen's state mutations.
  Widget _tileFor(Task todo) {
    final subCtrl =
        _subCtrl.putIfAbsent(todo.id, () => TextEditingController());
    final docId = todo.sharedId ?? todo.reminderDocId;
    return _TodoTile(
      todo: todo,
      isExpanded: _expanded.contains(todo.id),
      // Only reminders THIS phone sent to the other person appear in the map;
      // absent → not an outgoing reminder → no delivery badge.
      outgoingDelivered:
          docId != null ? _deliveryByDoc[docId] : null,
      subCtrl: subCtrl,
      onExpandToggle: () => setState(() => _expanded.contains(todo.id)
          ? _expanded.remove(todo.id)
          : _expanded.add(todo.id)),
      onEdit: () => _editTask(todo),
      onSetReminder: () => _setReminder(todo),
      onDelete: () => _delete(todo.id),
      onToggleDone: (v) => _toggleDone(todo, v),
      onToggleSubtask: (sub, v) => _toggleSubtask(todo, sub, v),
      onDeleteSubtask: (subId) => _deleteSubtask(todo, subId),
      onEditSubtask: (sub) => _editSubtask(todo, sub),
      onAddSubtask: () => _addSubtask(todo),
    );
  }

  /// "flutter" typed into the add-task field opens the chat.
  void _onInputChanged(String v) {
    if (v.trim().toLowerCase() == 'flutter') _openChat();
  }
}
