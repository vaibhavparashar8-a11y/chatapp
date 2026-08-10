import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart' show mySenderId, todoRefreshNotifier;
import '../models/recurrence.dart';
import '../models/task.dart';
import '../services/log_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../services/task_store.dart';
import '../theme/app_palette.dart';
import '../utils/time_utils.dart';

part 'calendar/calendar_grid.dart';
part 'calendar/calendar_day_list.dart';
part 'calendar/calendar_edit.dart';

/// A month view over the same reminders the todo list shows.
///
/// Deliberately not a separate "events" feature: it reads the very same
/// [Task] list from [TaskStore], so anything added here appears on the todo
/// screen and vice versa. There are no start/end times or durations — a task
/// is a title plus one instant, and a repeating one is drawn on every day it
/// occurs (see [Task.occursOn]).
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  List<Task> _tasks = [];

  /// First day of the month on show.
  late DateTime _month;

  /// The day whose reminders are listed below the grid.
  late DateTime _selected;

  /// Whose reminders to draw. Both on by default; the last one cannot be
  /// unticked, so the grid is never inexplicably empty.
  bool _showMine = true;
  bool _showTheirs = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _selected = DateTime(now.year, now.month, now.day);
    unawaited(_load());
    // A reminder arriving from the other phone rewrites the stored list.
    todoRefreshNotifier.addListener(_onRemoteChange);
  }

  @override
  void dispose() {
    todoRefreshNotifier.removeListener(_onRemoteChange);
    super.dispose();
  }

  void _onRemoteChange() => unawaited(_load());

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tasks = await TaskStore.load(prefs);
      if (!mounted) return;
      setState(() => _tasks = tasks);
    } catch (e) {
      LogService.e('calendar', 'could not load tasks: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not load your reminders.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final json = await TaskStore.save(prefs, _tasks);
    unawaited(ReminderService.backupTodos(json)
        .catchError((e) => LogService.w('calendar', 'todo backup failed: $e')));
  }

  // ── Filtering ─────────────────────────────────────────────────────────────

  /// Tasks passing the Mine/Theirs filter. Only reminders already on this
  /// device are ever considered — your own tasks plus ones explicitly shared —
  /// so "Theirs" means "shared with me", not the other person's whole list.
  List<Task> get _visible => _tasks.where((t) {
        if (!t.hasReminder) return false;
        return t.isMine(mySenderId) ? _showMine : _showTheirs;
      }).toList();

  /// Visible reminders falling on [day], earliest first.
  List<Task> tasksOn(DateTime day) {
    final out = _visible.where((t) => t.occursOn(day)).toList();
    out.sort((a, b) {
      final at = a.occurrenceOn(day)!;
      final bt = b.occurrenceOn(day)!;
      return at.compareTo(bt);
    });
    return out;
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _stepMonth(int delta) => setState(() {
        _month = DateTime(_month.year, _month.month + delta);
      });

  void _goToday() => setState(() {
        final now = DateTime.now();
        _month = DateTime(now.year, now.month);
        _selected = DateTime(now.year, now.month, now.day);
      });

  void _select(DateTime day) => setState(() => _selected = day);

  /// `setState` cannot be called from an extension (it trips
  /// `invalid_use_of_protected_member`), so the add/edit helpers in
  /// `calendar_edit.dart` route their mutations back through this.
  void applyChange(VoidCallback change) {
    if (!mounted) return;
    setState(change);
  }

  @override
  Widget build(BuildContext context) {
    final dayTasks = tasksOn(_selected);
    return Scaffold(
      backgroundColor: kAppBg,
      appBar: AppBar(
        title: Text(monthYearLabel(_month),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [kAppBar1, kAppBar2],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous month',
            onPressed: () => _stepMonth(-1),
          ),
          TextButton(
            onPressed: _goToday,
            child: const Text('Today',
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next month',
            onPressed: () => _stepMonth(1),
          ),
        ],
      ),
      body: Column(
        children: [
          _OwnerFilter(
            showMine: _showMine,
            showTheirs: _showTheirs,
            onChanged: (mine, theirs) => setState(() {
              _showMine = mine;
              _showTheirs = theirs;
            }),
          ),
          _MonthGrid(
            month: _month,
            selected: _selected,
            countFor: (day) => tasksOn(day).length,
            onSelect: _select,
          ),
          const Divider(height: 1, color: kAppDivider),
          Expanded(
            child: _DayTimeline(
              // Rebuild the timeline from scratch when the day changes, so it
              // re-anchors its scroll on the new day's "now" / first reminder.
              key: ValueKey(_selected),
              day: _selected,
              tasks: dayTasks,
              onToggleDone: _toggleDone,
              onEdit: _editTask,
              onDelete: _deleteTask,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kAppAccentDeep,
        onPressed: _addForSelectedDay,
        tooltip: 'Add a reminder',
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}
