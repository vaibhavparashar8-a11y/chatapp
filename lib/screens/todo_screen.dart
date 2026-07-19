import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_screen.dart';
import '../services/device_service.dart';
import '../services/remote_config_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../services/call_log_service.dart';
import '../services/log_service.dart';
import '../services/digest_service.dart';
import '../models/recurrence.dart';
import '../constants.dart' show mySenderId, todoRefreshNotifier;
import '../utils/time_utils.dart';

// Split into `part` files to keep this screen approachable (see CLAUDE.md
// file-size guideline). Models and all presentational widgets live alongside;
// _TodoScreenState below owns the state and orchestration.
part 'todo/todo_theme.dart';
part 'todo/todo_models.dart';
part 'todo/todo_widgets.dart';
part 'todo/todo_tile.dart';
part 'todo/todo_dialogs.dart';
part 'todo/todo_reminders.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});
  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> with WidgetsBindingObserver {
  static const _todosKey = 'todos_v1';

  final _addCtrl = TextEditingController();
  final _addFocus = FocusNode();
  final _searchCtrl = TextEditingController();
  final Map<String, TextEditingController> _subCtrl = {};
  final Set<String> _expanded = {};
  List<_Todo> _todos = [];
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
    todoRefreshNotifier.addListener(_onRemoteTaskArrived);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(CallLogService.sync());
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
    var raw = prefs.getString(_todosKey);
    if (raw == null) {
      // Fresh install / cleared data: restore this device's Firestore backup
      // (role is reclaimed via ANDROID_ID) so local reminders survive reinstall.
      raw = await ReminderService.fetchTodoBackup();
      if (raw == null) return;
      await prefs.setString(_todosKey, raw); // persist so we don't refetch
    }
    try {
      final list = jsonDecode(raw) as List;
      if (!mounted) return;
      setState(() {
        _todos = list.map((e) {
          final subs = (e['subtasks'] as List? ?? [])
              .map((s) => _SubTodo(
                    s['id'] as String,
                    s['title'] as String,
                    done: s['done'] as bool? ?? false,
                  ))
              .toList();
          final id = e['id'] as String;
          return _Todo(
            id,
            e['title'] as String,
            done: e['done'] as bool? ?? false,
            dueDate: e['dueDate'] != null
                ? DateTime.parse(e['dueDate'] as String)
                : null,
            subtasks: subs,
            // Legacy shared copies (pre-sync) carry the doc ID in their local ID.
            sharedId: e['sharedId'] as String? ??
                (id.startsWith('reminder_')
                    ? id.substring('reminder_'.length)
                    : null),
            reminderDocId: e['reminderDocId'] as String?,
            recurrence: Recurrence.fromStorage(e['recurrence'] as String?),
          );
        }).toList();
      });
    } catch (_) {}
  }

  Future<void> _saveTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_todos
        .map((t) => {
              'id': t.id,
              'title': t.title,
              'done': t.done,
              if (t.sharedId != null) 'sharedId': t.sharedId,
              if (t.reminderDocId != null) 'reminderDocId': t.reminderDocId,
              if (t.dueDate != null) 'dueDate': t.dueDate!.toIso8601String(),
              if (t.recurrence != Recurrence.none)
                'recurrence': t.recurrence.storage,
              'subtasks': t.subtasks
                  .map((s) => {'id': s.id, 'title': s.title, 'done': s.done})
                  .toList(),
            })
        .toList());
    await prefs.setString(_todosKey, json);
    // Mirror to Firestore (role-keyed) so these reminders survive a reinstall.
    unawaited(ReminderService.backupTodos(json)
        .catchError((e) => LogService.w('todo', 'todo backup failed: $e')));
  }

  // ── Navigation ────────────────────────────────────────────────────────────

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
    final todo = _Todo(id, text);
    setState(() => _todos.insert(0, todo));
    _addCtrl.clear();
    await _saveTodos();

    if (!mounted) return;
    final want = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kTodoCard,
        titleTextStyle: _kTodoDialogTitle,
        contentTextStyle: _kTodoDialogContent,
        title: const Text('Set a reminder?'),
        content: Text('Add a reminder for "$text"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
              child: const Text('Skip')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: _kTodoAccentDeep),
              child: const Text('Set')),
        ],
      ),
    );
    if (want == true && mounted) {
      await _setReminder(todo);
    }
  }

  /// Single entry point for all reminder actions on a task.
  /// Picks date/time first, then shows a dialog to choose who gets reminded.
  Future<void> _setReminder(_Todo todo) async {
    final dueDate = await _pickDateTime(initial: todo.dueDate);
    if (dueDate == null || !mounted) return;

    bool remindSelf = true;
    bool remindOther = false;
    bool addToList = false;
    Recurrence recurrence = todo.recurrence;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kTodoCard,
          titleTextStyle: _kTodoDialogTitle,
          title: const Text('Set Reminder'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: remindSelf,
                    onChanged: (v) => setLocal(() => remindSelf = v ?? true),
                    activeColor: _kTodoAccent,
                    side: const BorderSide(color: Colors.white38, width: 1.5),
                  ),
                  const Expanded(
                      child: Text('Remind me',
                          style: TextStyle(color: _kTodoText))),
                ],
              ),
              Row(
                children: [
                  Checkbox(
                    value: remindOther,
                    onChanged: (v) => setLocal(() {
                      remindOther = v ?? false;
                      if (!remindOther) addToList = false;
                    }),
                    activeColor: _kTodoAccent,
                    side: const BorderSide(color: Colors.white38, width: 1.5),
                  ),
                  const Expanded(
                      child:
                          Text('Notify', style: TextStyle(color: _kTodoText))),
                ],
              ),
              if (remindOther)
                Row(
                  children: [
                    const SizedBox(width: 32),
                    Checkbox(
                      value: addToList,
                      onChanged: (v) =>
                          setLocal(() => addToList = v ?? false),
                      activeColor: _kTodoAccent,
                      side: const BorderSide(color: Colors.white38, width: 1.5),
                    ),
                    const Expanded(
                        child: Text('Add to notify task list',
                            style: TextStyle(color: _kTodoText))),
                  ],
                ),
              const Divider(color: _kTodoDivider, height: 20),
              Row(
                children: const [
                  Icon(Icons.repeat, size: 18, color: _kTodoAccentLight),
                  SizedBox(width: 10),
                  Text('Repeat', style: TextStyle(color: _kTodoText)),
                ],
              ),
              DropdownButton<Recurrence>(
                value: recurrence,
                isExpanded: true,
                dropdownColor: _kTodoCard,
                style: const TextStyle(color: _kTodoText),
                iconEnabledColor: _kTodoAccentLight,
                onChanged: (v) =>
                    setLocal(() => recurrence = v ?? Recurrence.none),
                items: [
                  for (final r in Recurrence.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: _kTodoAccentDeep),
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    if (remindSelf) {
      if (todo.dueDate != null) {
        await NotificationService.cancelReminderGroup(todo.id.hashCode);
      }
      setState(() {
        todo.dueDate = dueDate;
        todo.recurrence = recurrence;
      });
      await _saveTodos();
      final ok = await NotificationService.scheduleReminder(
        id: todo.id.hashCode,
        title: todo.title,
        scheduledTime: dueDate,
        recurrence: recurrence,
      );
      if (mounted) {
        final repeat = recurrence == Recurrence.none
            ? ''
            : ' · ${recurrence.shortLabel(dueDate)}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? 'Reminder set for ${formatDue(dueDate)}$repeat'
              : 'Could not set reminder. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }

    if (todo.backingDocId != null) {
      // This task already has a Firestore reminder doc (shared, self, or
      // remind-them). Push the new time to it instead of creating a duplicate —
      // for shared tasks the other side's mirror reschedules from it.
      ReminderService.updateSharedTask(todo.backingDocId!, scheduledAt: dueDate)
          .catchError((_) {});
    } else if (remindOther) {
      final otherId = mySenderId == 'A' ? 'B' : 'A';
      try {
        final docId = await ReminderService.createReminder(
          forUser: otherId,
          title: todo.title,
          scheduledAt: dueDate,
          addToList: addToList,
          // Mirror any existing sub-tasks so they show up on their phone too.
          subtasks: addToList ? _subtaskPayload(todo) : null,
        );
        if (docId != null) {
          // Link my copy so future edits/deletes reach the doc. addToList tasks
          // are mirrored (sharedId); others are stored-only (reminderDocId).
          if (addToList) {
            todo.sharedId = docId;
          } else {
            todo.reminderDocId = docId;
          }
          await _saveTodos();
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Notified'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not notify. Please try again.'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
    } else if (remindSelf) {
      // "Remind me" only: store a private backup doc in Firestore alongside the
      // local notification (already scheduled above). locallyScheduled=true so
      // the delivery paths and the Cloud Function skip it — no duplicate push.
      try {
        final docId = await ReminderService.createReminder(
          forUser: mySenderId,
          title: todo.title,
          scheduledAt: dueDate,
          addToList: false,
          locallyScheduled: true,
        );
        if (docId != null) {
          todo.reminderDocId = docId;
          await _saveTodos();
        }
      } catch (e) {
        // Backup is best-effort — the local reminder still fires. But surface
        // the failure rather than swallow it: a rejected write here means the
        // self reminder never reaches Firestore (its cross-device backup).
        LogService.e('todo', 'self reminder Firestore write failed: $e');
      }
    }
  }

  // ── Sub-tasks ─────────────────────────────────────────────────────────────

  void _addSubtask(_Todo todo) {
    final ctrl = _subCtrl.putIfAbsent(todo.id, () => TextEditingController());
    final text = ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => todo.subtasks
        .add(_SubTodo(DateTime.now().microsecondsSinceEpoch.toString(), text)));
    ctrl.clear();
    _saveTodos();
    _syncSubtasks(todo);
  }

  void _toggleSubtask(_Todo todo, _SubTodo sub, bool? val) {
    setState(() => sub.done = val ?? false);
    _saveTodos();
    _syncSubtasks(todo);
  }

  void _deleteSubtask(_Todo todo, String subId) {
    setState(() => todo.subtasks.removeWhere((s) => s.id == subId));
    _saveTodos();
    _syncSubtasks(todo);
  }

  /// Rename a sub-task via a small dialog; writes through for shared tasks.
  Future<void> _editSubtask(_Todo todo, _SubTodo sub) async {
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
  List<Map<String, dynamic>> _subtaskPayload(_Todo todo) => todo.subtasks
      .map((s) => {'id': s.id, 'title': s.title, 'done': s.done})
      .toList();

  /// Push a mirrored shared task's sub-tasks to its reminder doc so the other
  /// device sees the change. Only `sharedId` tasks are mirrored — stored-only
  /// reminders (reminderDocId) aren't shown on the other phone, so skip them.
  void _syncSubtasks(_Todo todo) {
    final sid = todo.sharedId;
    if (sid == null) return;
    ReminderService.updateSharedTask(sid, subtasks: _subtaskPayload(todo))
        .catchError((e) => LogService.w('todo', 'subtask sync failed: $e'));
  }

  // ── Task management ───────────────────────────────────────────────────────

  void _toggleDone(_Todo todo, bool? val) {
    setState(() => todo.done = val ?? false);
    _saveTodos();
    if (todo.backingDocId != null) {
      ReminderService.updateSharedTask(todo.backingDocId!, done: todo.done)
          .catchError((_) {}); // offline edit — Firestore retries when back online
    }
  }

  void _delete(String id) {
    final idx = _todos.indexWhere((t) => t.id == id);
    // Any Firestore reminder doc backing this task — mirrored (sharedId) or
    // stored-only (reminderDocId, i.e. self / remind-them). Deleting the task
    // deletes its doc so it never lingers in Firestore.
    final docId = idx != -1 ? _todos[idx].backingDocId : null;
    if (idx != -1 && _todos[idx].dueDate != null) {
      // Group cancel in case this reminder was recurring (weekdays/weekends
      // schedule several notifications under derived ids).
      NotificationService.cancelReminderGroup(id.hashCode);
      if (docId != null) {
        NotificationService.cancelReminder(docId.hashCode.abs() % 0x7FFFFFFF);
      }
    }
    _subCtrl.remove(id)?.dispose();
    _expanded.remove(id);
    setState(() => _todos.removeWhere((t) => t.id == id));
    _saveTodos();
    if (docId != null) {
      ReminderService.deleteSharedTask(docId).catchError((_) {});
    }
  }

  /// Long-press on a task tile — rename it. Shared tasks push the new title
  /// to Firestore so the other person's copy updates too.
  Future<void> _editTask(_Todo todo) async {
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
    if (todo.dueDate != null &&
        !todo.done &&
        (todo.recurrence != Recurrence.none ||
            todo.dueDate!.isAfter(DateTime.now()))) {
      await NotificationService.cancelReminderGroup(todo.id.hashCode);
      await NotificationService.scheduleReminder(
        id: todo.id.hashCode,
        title: trimmed,
        scheduledTime: todo.dueDate!,
        recurrence: todo.recurrence,
      );
    }
    if (todo.backingDocId != null) {
      ReminderService.updateSharedTask(todo.backingDocId!, title: trimmed)
          .catchError((_) {});
    }
  }

  // ── Role reset (debug only) ───────────────────────────────────────────────

  Future<void> _showRoleResetDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kTodoCard,
        titleTextStyle: _kTodoDialogTitle,
        contentTextStyle: _kTodoDialogContent,
        title: const Text('Reset Role Assignment?'),
        content: const Text(
          'Clears A/B roles for this device and wipes Firestore assignment. '
          'Both devices must relaunch after resetting.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DeviceService.resetAssignments();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Role reset. Relaunch both devices.'),
      duration: Duration(seconds: 5),
      behavior: SnackBarBehavior.floating,
    ));
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
  Widget _tileFor(_Todo todo) {
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
