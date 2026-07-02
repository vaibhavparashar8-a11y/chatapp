import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'constants.dart';
import 'services/notification_service.dart';
import 'services/reminder_service.dart';

const kReminderTaskName = 'checkReminders';
const _roleKey = 'sender_role';
const _roomKey = '_bgChatRoomId';
const _todosKey = 'todos_v1';

/// WorkManager entry point — runs in a background Dart isolate.
/// Must be a top-level function annotated with vm:entry-point.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();

    // ── Firebase ────────────────────────────────────────────────────────────
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    } catch (_) {
      return true; // Firebase unavailable — skip silently, retry next interval
    }

    // ── Identity ────────────────────────────────────────────────────────────
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString(_roleKey);
    if (role == null || role.isEmpty) return true; // app never fully launched

    // Set globals used by ReminderService / NotificationService
    mySenderId = role;
    chatRoomId = prefs.getString(_roomKey) ?? kDefaultChatRoomId;

    // ── Notifications ───────────────────────────────────────────────────────
    try {
      await NotificationService.init();
    } catch (_) {
      return true; // can't schedule without notifications — skip
    }

    // ── Process pending reminders ───────────────────────────────────────────
    List<PendingReminder> pending;
    try {
      pending = await ReminderService.fetchPending(role, chatRoomId);
    } catch (_) {
      return true; // Firestore unreachable — will retry at next interval
    }

    for (final r in pending) {
      // Skip reminders already in the past (more than 1 min ago).
      if (r.scheduledAt.isBefore(DateTime.now().subtract(const Duration(minutes: 1)))) {
        // Still mark it so we don't keep re-fetching it.
        try { await ReminderService.markScheduled(r.id, chatRoomId); } catch (_) {}
        continue;
      }

      // Schedule the local notification — identical to a self-set reminder
      // (no sender attribution → discrete).
      bool scheduled = false;
      try {
        scheduled = await NotificationService.scheduleReminder(
          id: r.id.hashCode.abs() % 0x7FFFFFFF,
          title: r.title,
          scheduledTime: r.scheduledAt,
        );
      } catch (_) {
        continue; // leave locallyScheduled=false so we retry next interval
      }

      if (!scheduled) continue;

      // Optionally insert into B's todo list in SharedPreferences.
      if (r.addToList) {
        try {
          await _insertTodo(prefs, r);
        } catch (_) {
          // Non-fatal — notification is already scheduled
        }
      }

      // Only mark done after successful scheduling.
      try {
        await ReminderService.markScheduled(r.id, chatRoomId);
      } catch (_) {
        // Will be re-fetched next run; notification is already scheduled so
        // the duplicate-guard in _insertTodo prevents double list entries.
      }
    }

    return true;
  });
}

/// Insert a reminder as a todo task into SharedPreferences.
/// Guards against duplicates in case the worker runs twice.
Future<void> _insertTodo(SharedPreferences prefs, PendingReminder r) async {
  final raw = prefs.getString(_todosKey);
  final list = raw != null ? jsonDecode(raw) as List : <dynamic>[];
  final guardId = 'reminder_${r.id}';
  if (list.any((e) => (e as Map)['id'] == guardId)) return; // already added
  list.insert(0, {
    'id': guardId,
    'title': r.title,
    'done': false,
    'dueDate': r.scheduledAt.toIso8601String(),
    'subtasks': <dynamic>[],
  });
  await prefs.setString(_todosKey, jsonEncode(list));
}
