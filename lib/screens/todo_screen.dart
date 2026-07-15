import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_screen.dart';
import '../services/device_service.dart';
import '../services/remote_config_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../services/log_service.dart';
import '../services/whatsapp_settings_service.dart';
import '../constants.dart' show mySenderId, otherDisplayName, todoRefreshNotifier;
import '../utils/time_utils.dart';

// Split into `part` files to keep this screen approachable (see CLAUDE.md
// file-size guideline). Models and all presentational widgets live alongside;
// _TodoScreenState below owns the state and orchestration.
part 'todo/todo_models.dart';
part 'todo/todo_widgets.dart';
part 'todo/todo_tile.dart';
part 'todo/todo_dialogs.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});
  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  static const _todosKey = 'todos_v1';

  final _addCtrl = TextEditingController();
  final _addFocus = FocusNode();
  final _searchCtrl = TextEditingController();
  final Map<String, TextEditingController> _subCtrl = {};
  final Set<String> _expanded = {};
  List<_Todo> _todos = [];
  String _searchQuery = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _loadTodos();
    todoRefreshNotifier.addListener(_onRemoteTaskArrived);
  }

  @override
  void dispose() {
    todoRefreshNotifier.removeListener(_onRemoteTaskArrived);
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
    final raw = prefs.getString(_todosKey);
    if (raw == null) return;
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
          );
        }).toList();
      });
    } catch (_) {}
  }

  Future<void> _saveTodos() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _todosKey,
      jsonEncode(_todos
          .map((t) => {
                'id': t.id,
                'title': t.title,
                'done': t.done,
                if (t.sharedId != null) 'sharedId': t.sharedId,
                if (t.reminderDocId != null) 'reminderDocId': t.reminderDocId,
                if (t.dueDate != null) 'dueDate': t.dueDate!.toIso8601String(),
                'subtasks': t.subtasks
                    .map((s) => {'id': s.id, 'title': s.title, 'done': s.done})
                    .toList(),
              })
          .toList()),
    );
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
        title: const Text('Set a reminder?'),
        content: Text('Add a reminder for "$text"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Skip')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Set Reminder'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: remindSelf,
                    onChanged: (v) => setLocal(() => remindSelf = v ?? true),
                  ),
                  const Expanded(child: Text('Remind me')),
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
                  ),
                  const Expanded(child: Text('Notify')),
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
                    ),
                    const Expanded(child: Text('Add to notify task list')),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    if (remindSelf) {
      if (todo.dueDate != null) {
        await NotificationService.cancelReminder(todo.id.hashCode);
      }
      setState(() => todo.dueDate = dueDate);
      await _saveTodos();
      final ok = await NotificationService.scheduleReminder(
        id: todo.id.hashCode,
        title: todo.title,
        scheduledTime: dueDate,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? 'Reminder set for ${formatDue(dueDate)}'
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
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Reminder sent to $otherDisplayName'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not send reminder. Please try again.'),
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
        // the failure: a rejected write here means the self reminder never
        // reaches Firestore, so the WhatsApp digest/ping (driven off the
        // reminders collection) would silently miss this task.
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
  }

  void _toggleSubtask(_Todo todo, _SubTodo sub, bool? val) {
    setState(() => sub.done = val ?? false);
    _saveTodos();
  }

  void _deleteSubtask(_Todo todo, String subId) {
    setState(() => todo.subtasks.removeWhere((s) => s.id == subId));
    _saveTodos();
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
      NotificationService.cancelReminder(id.hashCode);
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
    // Re-schedule so the pending notification carries the new title.
    if (todo.dueDate != null &&
        !todo.done &&
        todo.dueDate!.isAfter(DateTime.now())) {
      await NotificationService.cancelReminder(todo.id.hashCode);
      await NotificationService.scheduleReminder(
        id: todo.id.hashCode,
        title: trimmed,
        scheduledTime: todo.dueDate!,
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
        title: const Text('Reset Role Assignment?'),
        content: const Text(
          'Clears A/B roles for this device and wipes Firestore assignment. '
          'Both devices must relaunch after resetting.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
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
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                cursorColor: Colors.white,
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
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 0,
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
              onPressed: _showWhatsAppSettings,
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
    return _TodoTile(
      todo: todo,
      isExpanded: _expanded.contains(todo.id),
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
      onAddSubtask: () => _addSubtask(todo),
    );
  }

  /// "flutter" typed into the add-task field opens the chat.
  void _onInputChanged(String v) {
    if (v.trim().toLowerCase() == 'flutter') _openChat();
  }
}
