import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';
import '../models/recurrence.dart';
import '../models/task.dart';
import 'notification_service.dart';
import 'task_store.dart';

/// A reminder fetched from Firestore that hasn't been locally scheduled yet.
class PendingReminder {
  final String id;
  final String title;
  final DateTime scheduledAt;
  final bool addToList;

  /// How the reminder repeats, as set by the creator. Carried across so the
  /// recipient's phone arms the same repeat instead of a one-shot.
  final Recurrence recurrence;

  /// Which role created the reminder — `'A'` or `'B'`. Carried onto the local
  /// copy so the calendar can tell mine from theirs.
  final String? createdBy;

  const PendingReminder({
    required this.id,
    required this.title,
    required this.scheduledAt,
    required this.addToList,
    this.recurrence = Recurrence.none,
    this.createdBy,
  });
}

/// Current state of a shared task (a reminder created with addToList=true).
/// The Firestore reminder doc is the source of truth both devices mirror.
class SharedTask {
  final String id;
  final String title;
  final DateTime scheduledAt;
  /// null on docs created before done-sync existed — means "unknown, don't sync".
  final bool? done;

  /// Sub-tasks as stored on the doc: `[{id, title, done}, …]`. null on docs
  /// that predate subtask-sync — means "unknown, don't touch the local copy".
  final List<Map<String, dynamic>>? subtasks;

  /// How the reminder repeats. Docs written before recurrence-sync carry no
  /// field and parse back as "does not repeat" — matching their old behaviour.
  final Recurrence recurrence;

  /// Which role created the reminder — `'A'` or `'B'`. Carried onto the local
  /// copy so the calendar can tell mine from theirs.
  final String? createdBy;

  const SharedTask({
    required this.id,
    required this.title,
    required this.scheduledAt,
    this.done,
    this.subtasks,
    this.recurrence = Recurrence.none,
    this.createdBy,
  });
}

/// One emission of [ReminderService.sharedTasksStream].
class SharedTasksSnapshot {
  final List<SharedTask> tasks;
  /// True when served from Firestore's local cache — the doc set may be
  /// incomplete, so deletions must not be applied from such a snapshot.
  final bool fromCache;
  const SharedTasksSnapshot(this.tasks, {required this.fromCache});
}

class ReminderService {
  static bool testMode = false;

  static final _db = FirebaseFirestore.instance;

  static CollectionReference _col(String roomId) =>
      _db.collection('rooms').doc(roomId).collection('reminders');

  // ── Local todo backup (survives reinstall) ─────────────────────────────────
  // The local todo list lives in SharedPreferences, which is wiped on
  // uninstall. Mirror it to a role-keyed Firestore doc so a reinstall (which
  // reclaims the same role via ANDROID_ID) can restore it. This is the whole
  // list as one JSON blob — private to this device's role.

  static DocumentReference _todoBackupDoc() => _db
      .collection('rooms')
      .doc(chatRoomId)
      .collection('todoBackups')
      .doc(mySenderId);

  /// Test seam: when set, [fetchTodoBackup] returns this instead of reading
  /// Firestore (so restore-on-fresh-install is widget-testable).
  @visibleForTesting
  static String? debugTodoBackup;

  /// Mirror this device's full todo list (JSON) to Firestore, keyed by role.
  static Future<void> backupTodos(String json) async {
    if (testMode) return;
    await _todoBackupDoc().set({
      'data': json,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// This device's todo backup JSON (role-keyed), or null if none exists.
  static Future<String?> fetchTodoBackup() async {
    if (debugTodoBackup != null) return debugTodoBackup;
    if (testMode) return null;
    final snap = await _todoBackupDoc().get();
    if (!snap.exists) return null;
    final data = snap.data() as Map<String, dynamic>?;
    return data?['data'] as String?;
  }

  /// A sets a reminder for B. [forUser] is the recipient's role ('A' or 'B').
  /// Returns the new doc's ID so the caller can link its local task copy to
  /// the shared doc (enables edit/delete sync for addToList tasks).
  ///
  /// Pass [locallyScheduled] `true` for a "Remind me" self reminder: the
  /// creator has already scheduled its local notification, so both the delivery
  /// paths (pendingStream / background worker) and the onReminderCreated Cloud
  /// Function must skip it to avoid a duplicate notification.
  static Future<String?> createReminder({
    required String forUser,
    required String title,
    required DateTime scheduledAt,
    required bool addToList,
    bool locallyScheduled = false,
    List<Map<String, dynamic>>? subtasks,
    Recurrence recurrence = Recurrence.none,
  }) async {
    if (testMode) return null;
    final doc = await _col(chatRoomId).add({
      'forUser': forUser,
      'title': title,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'addToList': addToList,
      'locallyScheduled': locallyScheduled,
      'done': false,
      if (recurrence != Recurrence.none) 'recurrence': recurrence.storage,
      if (subtasks != null && subtasks.isNotEmpty) 'subtasks': subtasks,
      'createdBy': mySenderId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }

  // ── Shared task sync ───────────────────────────────────────────────────────
  // A task created with "Add to their task list" exists on both phones. The
  // reminder doc is the shared source of truth: edits, done-toggles and
  // deletes on either side write through to the doc, and each device mirrors
  // the doc set back into its local SharedPreferences list.

  /// Push a local edit of a shared task to Firestore.
  static Future<void> updateSharedTask(
    String docId, {
    String? title,
    DateTime? scheduledAt,
    bool? done,
    List<Map<String, dynamic>>? subtasks,
    Recurrence? recurrence,
  }) async {
    if (testMode) return;
    final data = <String, dynamic>{
      if (title != null) 'title': title,
      if (scheduledAt != null) 'scheduledAt': Timestamp.fromDate(scheduledAt),
      if (done != null) 'done': done,
      if (subtasks != null) 'subtasks': subtasks,
      // Written even for `none` so clearing a repeat reaches the other phone.
      if (recurrence != null) 'recurrence': recurrence.storage,
      'updatedBy': mySenderId,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    await _col(chatRoomId).doc(docId).update(data);
  }

  /// Delete a shared task's doc — the other device's mirror removes its copy.
  static Future<void> deleteSharedTask(String docId) async {
    if (testMode) return;
    await _col(chatRoomId).doc(docId).delete();
  }

  // ── Delivery confirmation ──────────────────────────────────────────────────
  // A reminder THIS phone sent to the other person carries `locallyScheduled`,
  // which the recipient's phone flips to true the moment it receives and arms
  // the notification. Watching it lets the sender show "Delivered to their
  // phone" — the reliable signal that the reminder actually reached them.

  /// Reduce reminder docs to the delivery status of the ones [me] SENT to the
  /// other person: `{docId: locallyScheduled}`. A doc is outgoing when this
  /// device created it (`createdBy == me`) for the other user (`forUser != me`)
  /// — so self reminders and the peer's own reminders are excluded.
  @visibleForTesting
  static Map<String, bool> deliveryMapFromDocs(
    Iterable<
            ({
              String id,
              String? createdBy,
              String? forUser,
              bool locallyScheduled
            })>
        docs,
    String me,
  ) {
    final out = <String, bool>{};
    for (final d in docs) {
      if (d.createdBy == me && d.forUser != me) {
        out[d.id] = d.locallyScheduled;
      }
    }
    return out;
  }

  /// Test seam: when set, [outgoingDeliveryStream] returns this instead of a
  /// live Firestore query.
  @visibleForTesting
  static Stream<Map<String, bool>>? debugDeliveryStream;

  /// Live delivery status of reminders this device sent to the other person,
  /// as `{docId: locallyScheduled}`. Index-free: filters on the single
  /// `createdBy` equality and splits `forUser` in memory via [deliveryMapFromDocs].
  static Stream<Map<String, bool>> outgoingDeliveryStream() {
    if (debugDeliveryStream != null) return debugDeliveryStream!;
    if (testMode) return const Stream.empty();
    return _col(chatRoomId)
        .where('createdBy', isEqualTo: mySenderId)
        .snapshots()
        .map((snap) => deliveryMapFromDocs(
              snap.docs.map((d) {
                final data = d.data() as Map<String, dynamic>;
                return (
                  id: d.id,
                  createdBy: data['createdBy'] as String?,
                  forUser: data['forUser'] as String?,
                  locallyScheduled:
                      (data['locallyScheduled'] as bool?) ?? false,
                );
              }),
              mySenderId,
            ));
  }

  static SharedTask _sharedTaskFromDoc(
      String id, Map<String, dynamic> data) {
    return SharedTask(
      id: id,
      title: (data['title'] as String?)?.trim().isNotEmpty == true
          ? data['title'] as String
          : 'Reminder',
      scheduledAt: (data['scheduledAt'] as Timestamp).toDate(),
      done: data['done'] as bool?,
      recurrence: Recurrence.fromStorage(data['recurrence'] as String?),
      createdBy: data['createdBy'] as String?,
      subtasks: (data['subtasks'] as List?)
          ?.map((s) => {
                'id': (s as Map)['id'] as String,
                'title': s['title'] as String,
                'done': s['done'] as bool? ?? false,
              })
          .toList(),
    );
  }

  /// Real-time stream of all shared tasks in the room (both directions).
  static Stream<SharedTasksSnapshot> sharedTasksStream() {
    if (testMode) return const Stream.empty();
    return _col(chatRoomId)
        .where('addToList', isEqualTo: true)
        .snapshots()
        .map((snap) => SharedTasksSnapshot(
              snap.docs
                  .map((d) => _sharedTaskFromDoc(
                      d.id, d.data() as Map<String, dynamic>))
                  .toList(),
              fromCache: snap.metadata.isFromCache,
            ));
  }

  /// One-shot fetch of shared tasks, forced from the server so an offline
  /// cache can never masquerade as an authoritative (deletion-applying) set.
  static Future<List<SharedTask>> fetchSharedTasks(String roomId) async {
    final snap = await _db
        .collection('rooms')
        .doc(roomId)
        .collection('reminders')
        .where('addToList', isEqualTo: true)
        .get(const GetOptions(source: Source.server));
    return snap.docs
        .map((d) => _sharedTaskFromDoc(d.id, d.data()))
        .toList();
  }

  /// Reconcile the local todo list in SharedPreferences against the current
  /// shared-doc set. Applies remote title/done/start changes to linked tasks
  /// and — when [applyDeletes] is true (server-confirmed snapshot) — removes
  /// local copies whose doc has been deleted by the other side.
  /// Returns true if the stored list changed.
  static Future<bool> applySharedSnapshot(
    SharedPreferences prefs,
    List<SharedTask> docs, {
    required bool applyDeletes,
  }) async {
    if (prefs.getString(TaskStore.key) == null &&
        prefs.getString(TaskStore.legacyKey) == null) {
      return false;
    }
    final tasks = await TaskStore.load(prefs);
    final byId = {for (final d in docs) d.id: d};
    bool changed = false;
    final removed = <Task>[];

    for (final task in tasks) {
      // Task.fromJson already backfills sharedId from a legacy
      // "reminder_<docId>" local id, so a pre-sync entry links itself on load.
      final sid = task.sharedId;
      if (sid == null) continue; // not a shared task

      final doc = byId[sid];
      if (doc == null) {
        if (applyDeletes) removed.add(task);
        continue;
      }

      if (task.title != doc.title) {
        task.title = doc.title;
        changed = true;
      }
      if (doc.done != null && task.done != doc.done) {
        task.done = doc.done!;
        changed = true;
      }
      // Sub-tasks: last-write-wins on the whole list. null means the doc
      // predates subtask-sync — leave the local copy untouched.
      if (doc.subtasks != null && !_subtasksEqual(task.subtasks, doc.subtasks!)) {
        task.subtasks =
            doc.subtasks!.map((s) => SubTask.fromJson(s)).toList();
        changed = true;
      }
      // Backfill the creator on copies stored before the field existed, so the
      // calendar's Mine/Theirs filter can place them.
      if (task.createdBy == null && doc.createdBy != null) {
        task.createdBy = doc.createdBy;
        changed = true;
      }
      // Start + repeat: only synced onto tasks that already track a start.
      // The creator may have declined "Remind me" — their copy has no start
      // and must not begin firing notifications because the other side
      // changed the time.
      if (task.start != null) {
        final startChanged = task.start != doc.scheduledAt;
        final repeatChanged = task.recurrence != doc.recurrence;
        if (startChanged || repeatChanged) {
          task.start = doc.scheduledAt;
          task.recurrence = doc.recurrence;
          changed = true;
          await _cancelNotificationsFor(task.id, sid);
          // A repeating reminder re-arms even when this occurrence has already
          // passed — its future occurrences still fire. One-shots do not.
          final stillFires = doc.recurrence != Recurrence.none ||
              doc.scheduledAt.isAfter(DateTime.now());
          if (!task.done && stillFires) {
            await NotificationService.scheduleReminder(
              id: task.id.hashCode,
              title: doc.title,
              scheduledTime: doc.scheduledAt,
              recurrence: doc.recurrence,
            );
          }
        }
      }
    }

    for (final task in removed) {
      changed = true;
      await _cancelNotificationsFor(task.id, task.sharedId!);
      tasks.remove(task);
    }

    if (changed) await TaskStore.save(prefs, tasks);
    return changed;
  }

  /// Value-compare a local subtask list against a doc's, by id/title/done in
  /// order — so an identical set never triggers a needless rewrite (which
  /// would loop the two devices).
  static bool _subtasksEqual(
      List<SubTask> local, List<Map<String, dynamic>> doc) {
    if (local.length != doc.length) return false;
    for (var i = 0; i < doc.length; i++) {
      final l = local[i];
      final r = doc[i];
      if (l.id != r['id'] ||
          l.title != r['title'] ||
          l.done != (r['done'] as bool? ?? false)) {
        return false;
      }
    }
    return true;
  }

  /// A shared task may have a notification scheduled under either the local
  /// todo ID hash (self-set via the alarm button) or the doc-ID hash (set by
  /// the FCM/WorkManager delivery path) — cancel both.
  static Future<void> _cancelNotificationsFor(String localId, String sid) async {
    // Group-cancel the local family: a repeating reminder (weekdays/weekends)
    // is armed under several weekday-derived ids, not just the base one.
    await NotificationService.cancelReminderGroup(localId.hashCode);
    await NotificationService.cancelReminder(NotificationService.docNotifId(sid));
  }

  /// Fetch reminders addressed to [forUser] that haven't been locally
  /// scheduled yet. Called from the background worker.
  static Future<List<PendingReminder>> fetchPending(
      String forUser, String roomId) async {
    final snap = await _db
        .collection('rooms')
        .doc(roomId)
        .collection('reminders')
        .where('forUser', isEqualTo: forUser)
        .where('locallyScheduled', isEqualTo: false)
        .get();
    return snap.docs.map((d) => _pendingFromDoc(d.id, d.data())).toList();
  }

  static PendingReminder _pendingFromDoc(
          String id, Map<String, dynamic> data) =>
      PendingReminder(
        id: id,
        title: (data['title'] as String?)?.trim().isNotEmpty == true
            ? data['title'] as String
            : 'Reminder',
        scheduledAt: (data['scheduledAt'] as Timestamp).toDate(),
        addToList: (data['addToList'] as bool?) ?? false,
        recurrence: Recurrence.fromStorage(data['recurrence'] as String?),
        createdBy: data['createdBy'] as String?,
      );

  /// Mark a reminder as locally scheduled so the background worker skips it
  /// on subsequent runs.
  static Future<void> markScheduled(String docId, String roomId) async {
    await _db
        .collection('rooms')
        .doc(roomId)
        .collection('reminders')
        .doc(docId)
        .update({'locallyScheduled': true});
  }

  /// Real-time stream of new reminders addressed to [forUser] that haven't
  /// been locally scheduled yet. Fires within seconds of the sender writing
  /// to Firestore — the foreground delivery path for instant reminders.
  static Stream<PendingReminder> pendingStream(String forUser) {
    if (testMode) return const Stream.empty();
    return _db
        .collection('rooms')
        .doc(chatRoomId)
        .collection('reminders')
        .where('forUser', isEqualTo: forUser)
        .where('locallyScheduled', isEqualTo: false)
        .snapshots()
        .expand((snap) => snap.docChanges
            .where((c) => c.type == DocumentChangeType.added)
            .map((c) => _pendingFromDoc(c.doc.id, c.doc.data()!)));
  }

  /// Insert a reminder as a todo task into SharedPreferences.
  /// Guards against duplicates so it's safe to call from both the foreground
  /// stream handler and the background FCM/WorkManager worker.
  static Future<void> insertTodoToPrefs(
      SharedPreferences prefs, PendingReminder r) async {
    final tasks = await TaskStore.load(prefs);
    final guardId = 'reminder_${r.id}';
    if (tasks.any((t) => t.id == guardId)) return;
    tasks.insert(
      0,
      Task(
        guardId,
        r.title,
        sharedId: r.id,
        start: r.scheduledAt,
        recurrence: r.recurrence,
        // The other phone created it — without this the calendar would file
        // every received reminder under "Mine".
        createdBy: r.createdBy,
      ),
    );
    await TaskStore.save(prefs, tasks);
  }
}
