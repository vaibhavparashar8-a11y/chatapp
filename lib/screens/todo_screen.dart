import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_screen.dart';
import '../services/device_service.dart';
import '../services/remote_config_service.dart';
import '../services/notification_service.dart';
import '../utils/time_utils.dart';

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

  _Todo(this.id, this.title,
      {this.done = false, this.dueDate, List<_SubTodo>? subtasks})
      : subtasks = subtasks ?? [];

  int get doneSubtasks => subtasks.where((s) => s.done).length;
}

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
  final Map<String, TextEditingController> _subCtrl = {};
  final Set<String> _expanded = {};
  List<_Todo> _todos = [];

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  @override
  void dispose() {
    _addCtrl.dispose();
    _addFocus.dispose();
    for (final c in _subCtrl.values) c.dispose();
    super.dispose();
  }

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
          return _Todo(
            e['id'] as String,
            e['title'] as String,
            done: e['done'] as bool? ?? false,
            dueDate: e['dueDate'] != null
                ? DateTime.parse(e['dueDate'] as String)
                : null,
            subtasks: subs,
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

    final dueDate = await _promptReminderOnCreate(text);
    if (!mounted) return;

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() => _todos.insert(0, _Todo(id, text, dueDate: dueDate)));
    _addCtrl.clear();
    await _saveTodos();

    if (dueDate != null) {
      final ok = await NotificationService.scheduleReminder(
        id: id.hashCode,
        title: text,
        scheduledTime: dueDate,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Could not set reminder. Tap the alarm icon to try again.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<DateTime?> _promptReminderOnCreate(String title) async {
    if (!mounted) return null;
    final want = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set a reminder?'),
        content: Text('Add a reminder for "$title"?'),
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
    if (want != true || !mounted) return null;
    return _pickDateTime();
  }

  Future<void> _setCalendarReminder(_Todo todo) async {
    final dueDate = await _pickDateTime(initial: todo.dueDate);
    if (dueDate == null || !mounted) return;
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

  Future<DateTime?> _pickDateTime({DateTime? initial}) async {
    final now = DateTime.now();
    final init = initial != null && initial.isAfter(now)
        ? initial
        : now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Pick reminder date',
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? init),
      helpText: 'Pick reminder time',
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
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
  }

  void _delete(String id) {
    final idx = _todos.indexWhere((t) => t.id == id);
    if (idx != -1 && _todos[idx].dueDate != null) {
      NotificationService.cancelReminder(id.hashCode);
    }
    _subCtrl.remove(id)?.dispose();
    _expanded.remove(id);
    setState(() => _todos.removeWhere((t) => t.id == id));
    _saveTodos();
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

  @override
  Widget build(BuildContext context) {
    final pending = _todos.where((t) => !t.done).toList();
    final done = _todos.where((t) => t.done).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: GestureDetector(
          onDoubleTap: kDebugMode ? _showRoleResetDialog : null,
          child: const Text('My Tasks',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
        ),
        centerTitle: false,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: _buildHeaderStats(pending.length, done.length),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              children: [
                if (pending.isEmpty && done.isEmpty)
                  _buildEmptyState()
                else ...[
                  ...pending.map(_buildTile),
                  if (done.isNotEmpty) ...[
                    _buildSectionHeader('Completed', done.length),
                    ...done.map(_buildTile),
                  ],
                ],
              ],
            ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildHeaderStats(int pending, int done) {
    return Container(
      color: Colors.indigo.shade700,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          Icon(Icons.pending_actions_rounded,
              size: 13, color: Colors.indigo.shade200),
          const SizedBox(width: 4),
          Text('$pending pending',
              style:
                  TextStyle(color: Colors.indigo.shade200, fontSize: 12)),
          if (done > 0) ...[
            const SizedBox(width: 14),
            Icon(Icons.check_circle_outline,
                size: 13, color: Colors.indigo.shade200),
            const SizedBox(width: 4),
            Text('$done done',
                style: TextStyle(
                    color: Colors.indigo.shade200, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          Icon(Icons.checklist_rounded,
              size: 72, color: Colors.indigo.shade100),
          const SizedBox(height: 16),
          const Text('No tasks yet',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black38)),
          const SizedBox(height: 6),
          const Text('Add a task below to get started',
              style: TextStyle(fontSize: 13, color: Colors.black26)),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Text(
            '${label.toUpperCase()} ($count)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade500,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: Colors.grey.shade300, height: 1)),
        ],
      ),
    );
  }

  Widget _buildTile(_Todo todo) {
    final hasReminder = todo.dueDate != null;
    final isOverdue =
        hasReminder && todo.dueDate!.isBefore(DateTime.now()) && !todo.done;
    final isExpanded = _expanded.contains(todo.id);

    Color accent;
    if (todo.done) {
      accent = Colors.grey.shade300;
    } else if (isOverdue) {
      accent = Colors.red.shade400;
    } else if (hasReminder) {
      accent = Colors.indigo.shade400;
    } else {
      accent = Colors.indigo.shade100;
    }

    return Dismissible(
      key: Key(todo.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.red.shade400,
            borderRadius: BorderRadius.circular(14)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      onDismissed: (_) => _delete(todo.id),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left accent stripe
                Container(width: 4, color: accent),
                // Card content
                Expanded(
                  child: Column(
                    children: [
                      // Main row — tap expands, checkbox toggles done
                      Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () => setState(() => isExpanded
                              ? _expanded.remove(todo.id)
                              : _expanded.add(todo.id)),
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(10, 10, 8, 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Circular checkbox
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                    value: todo.done,
                                    onChanged: (v) => _toggleDone(todo, v),
                                    activeColor: Colors.indigo,
                                    shape: const CircleBorder(),
                                    side: BorderSide(
                                      color: todo.done
                                          ? Colors.indigo
                                          : Colors.grey.shade400,
                                      width: 1.5,
                                    ),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Title + meta
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        todo.title,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                          decoration: todo.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                          color: todo.done
                                              ? Colors.grey.shade400
                                              : Colors.black87,
                                        ),
                                      ),
                                      if (hasReminder) ...[
                                        const SizedBox(height: 3),
                                        Row(children: [
                                          Icon(Icons.schedule_rounded,
                                              size: 11,
                                              color: isOverdue
                                                  ? Colors.red.shade400
                                                  : Colors.indigo.shade300),
                                          const SizedBox(width: 3),
                                          Text(
                                            formatDue(todo.dueDate!),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isOverdue
                                                  ? Colors.red.shade400
                                                  : Colors.indigo.shade300,
                                              fontWeight: isOverdue
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                        ]),
                                      ],
                                      if (todo.subtasks.isNotEmpty) ...[
                                        const SizedBox(height: 5),
                                        Row(children: [
                                          SizedBox(
                                            width: 72,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value: todo.doneSubtasks /
                                                    todo.subtasks.length,
                                                backgroundColor:
                                                    Colors.grey.shade200,
                                                color: todo.doneSubtasks ==
                                                        todo.subtasks.length
                                                    ? Colors.green.shade400
                                                    : Colors.indigo.shade300,
                                                minHeight: 3,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${todo.doneSubtasks}/${todo.subtasks.length}',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color:
                                                    Colors.grey.shade500),
                                          ),
                                        ]),
                                      ],
                                    ],
                                  ),
                                ),
                                // Alarm icon
                                IconButton(
                                  icon: Icon(
                                    hasReminder
                                        ? Icons.alarm_on_rounded
                                        : Icons.add_alarm_rounded,
                                    size: 19,
                                    color: isOverdue
                                        ? Colors.red.shade400
                                        : hasReminder
                                            ? Colors.indigo.shade400
                                            : Colors.grey.shade400,
                                  ),
                                  onPressed: () =>
                                      _setCalendarReminder(todo),
                                  padding: const EdgeInsets.all(6),
                                  constraints: const BoxConstraints(),
                                ),
                                const SizedBox(width: 2),
                                // Expand arrow
                                AnimatedRotation(
                                  turns: isExpanded ? 0.5 : 0,
                                  duration:
                                      const Duration(milliseconds: 200),
                                  child: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey.shade400,
                                    size: 22,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Sub-tasks section (animated)
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        child: isExpanded
                            ? Column(
                                children: [
                                  Divider(
                                      height: 1,
                                      color: Colors.grey.shade100,
                                      indent: 16),
                                  ...todo.subtasks
                                      .map((s) => _buildSubtaskRow(todo, s)),
                                  _buildSubtaskInput(todo),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubtaskRow(_Todo todo, _SubTodo sub) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: sub.done,
              onChanged: (v) => _toggleSubtask(todo, sub, v),
              activeColor: Colors.indigo.shade300,
              shape: const CircleBorder(),
              side: BorderSide(color: Colors.grey.shade300, width: 1.5),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sub.title,
              style: TextStyle(
                fontSize: 13,
                color: sub.done ? Colors.grey.shade400 : Colors.black54,
                decoration: sub.done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded,
                size: 16, color: Colors.grey.shade300),
            onPressed: () => _deleteSubtask(todo, sub.id),
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtaskInput(_Todo todo) {
    final ctrl = _subCtrl.putIfAbsent(todo.id, () => TextEditingController());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 10),
      child: Row(
        children: [
          Icon(Icons.add, size: 15, color: Colors.grey.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: ctrl,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
              decoration: InputDecoration(
                hintText: 'Add sub-task...',
                hintStyle:
                    TextStyle(color: Colors.grey.shade400, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addSubtask(todo),
            ),
          ),
          GestureDetector(
            onTap: () => _addSubtask(todo),
            child: Icon(Icons.send_rounded,
                size: 17, color: Colors.indigo.shade300),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 10, 16, MediaQuery.of(context).padding.bottom + 10),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _addCtrl,
              focusNode: _addFocus,
              textInputAction: TextInputAction.done,
              style: TextStyle(fontSize: 15, color: RemoteConfigService.todoInputTextColor),
              onChanged: (v) {
                if (v.trim().toLowerCase() == 'flutter') _openChat();
              },
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Add a task...',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                filled: true,
                fillColor: const Color(0xFFF5F5F7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FloatingActionButton(
            onPressed: _submit,
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            elevation: 2,
            mini: true,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
