import 'dart:convert';
import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_screen.dart';
import '../utils/time_utils.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _Todo {
  final String id;
  String title;
  bool done;
  DateTime? dueDate;

  _Todo(this.id, this.title, {this.done = false, this.dueDate});
}

class _TodoScreenState extends State<TodoScreen> {
  static const _todosKey = 'todos_v1';

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<_Todo> _todos = [];

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  Future<void> _loadTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_todosKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        if (mounted) {
          setState(() {
            _todos = list
                .map((e) => _Todo(
                      e['id'] as String,
                      e['title'] as String,
                      done: e['done'] as bool? ?? false,
                      dueDate: e['dueDate'] != null
                          ? DateTime.parse(e['dueDate'] as String)
                          : null,
                    ))
                .toList();
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _saveTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _todos
        .map((t) => {
              'id': t.id,
              'title': t.title,
              'done': t.done,
              if (t.dueDate != null) 'dueDate': t.dueDate!.toIso8601String(),
            })
        .toList();
    await prefs.setString(_todosKey, jsonEncode(list));
  }

  void _openChat() {
    _controller.clear();
    _focusNode.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ChatScreen()),
    );
  }

  void _onChanged(String value) {
    if (value.trim().toLowerCase() == 'flutter') _openChat();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (text.toLowerCase() == 'flutter') {
      _openChat();
      return;
    }
    setState(() {
      _todos.add(_Todo(
        DateTime.now().millisecondsSinceEpoch.toString(),
        text,
      ));
    });
    _controller.clear();
    _saveTodos();
  }

  void _toggleDone(_Todo todo, bool? val) {
    setState(() => todo.done = val ?? false);
    _saveTodos();
  }

  void _delete(String id) {
    setState(() => _todos.removeWhere((t) => t.id == id));
    _saveTodos();
  }

  Future<void> _setCalendarReminder(_Todo todo) async {
    final now = DateTime.now();
    final initial = todo.dueDate ?? now.add(const Duration(days: 1));

    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Pick reminder date',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Pick reminder time',
    );
    if (time == null || !mounted) return;

    final dueDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);

    setState(() => todo.dueDate = dueDate);
    await _saveTodos();

    final event = Event(
      title: todo.title,
      description: 'Reminder from MyTask: ${todo.title}',
      startDate: dueDate,
      endDate: dueDate.add(const Duration(hours: 1)),
      allDay: false,
    );

    final added = await Add2Calendar.addEvent2Cal(event);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(added
            ? 'Reminder set for ${formatDue(dueDate)}'
            : 'Could not open calendar'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _todos.where((t) => !t.done).toList();
    final completed = _todos.where((t) => t.done).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('My Tasks', style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: () {}),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              children: [
                if (pending.isEmpty && completed.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: Center(
                      child: Text(
                        'No tasks yet.\nTap + to add one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 15),
                      ),
                    ),
                  ),
                ...pending.map((todo) => _buildTile(todo)),
                if (completed.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Completed (${completed.length})',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  ...completed.map((todo) => _buildTile(todo)),
                ],
              ],
            ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildTile(_Todo todo) {
    final hasReminder = todo.dueDate != null;
    final isOverdue = hasReminder && todo.dueDate!.isBefore(DateTime.now()) && !todo.done;

    return Dismissible(
      key: Key(todo.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red[400],
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _delete(todo.id),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(10),
          child: CheckboxListTile(
          value: todo.done,
          onChanged: (val) => _toggleDone(todo, val),
          title: Text(
            todo.title,
            style: TextStyle(
              decoration: todo.done ? TextDecoration.lineThrough : null,
              color: todo.done ? Colors.grey : Colors.black87,
              fontSize: 15,
            ),
          ),
          subtitle: hasReminder
              ? Text(
                  formatDue(todo.dueDate!),
                  style: TextStyle(
                    fontSize: 11,
                    color: isOverdue ? Colors.red[400] : Colors.indigo[400],
                    fontWeight: isOverdue ? FontWeight.w600 : FontWeight.normal,
                  ),
                )
              : null,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: Colors.indigo,
          checkboxShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          secondary: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  hasReminder ? Icons.calendar_today : Icons.calendar_today_outlined,
                  color: isOverdue
                      ? Colors.red[400]
                      : hasReminder
                          ? Colors.indigo
                          : Colors.grey[400],
                  size: 20,
                ),
                tooltip: hasReminder ? 'Update reminder' : 'Set reminder',
                onPressed: () => _setCalendarReminder(todo),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.grey[400], size: 20),
                onPressed: () => _delete(todo.id),
              ),
            ],
          ),
        ),        // CheckboxListTile
        ),        // Material
      ),          // Container
    );            // Dismissible
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, -2)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: Color(0xFFDDDDDD)),
              onChanged: _onChanged,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Add a task...',
                hintStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: const Color(0xFFF0F0F0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.small(
            onPressed: _submit,
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            elevation: 0,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
