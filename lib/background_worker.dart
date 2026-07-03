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
          await ReminderService.insertTodoToPrefs(prefs, r);
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

    // ── Mirror shared-task edits/deletes made while the app was killed ──────
    // fetchSharedTasks forces a server read, so an offline device throws here
    // (skipped) rather than mass-deleting local tasks from an empty cache.
    try {
      final shared = await ReminderService.fetchSharedTasks(chatRoomId);
      await ReminderService.applySharedSnapshot(prefs, shared,
          applyDeletes: true);
    } catch (_) {
      // Server unreachable — retry next interval.
    }

    return true;
  });
}

