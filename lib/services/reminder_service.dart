import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';
import 'notification_service.dart';

/// A reminder fetched from Firestore that hasn't been locally scheduled yet.
class PendingReminder {
  final String id;
  final String title;
  final DateTime scheduledAt;
  final bool addToList;
  const PendingReminder({
    required this.id,
    required this.title,
    required this.scheduledAt,
    required this.addToList,
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
  const SharedTask({
    required this.id,
    required this.title,
    required this.scheduledAt,
    this.done,
    this.subtasks,
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
  }) async {
    if (testMode) return null;
    final doc = await _col(chatRoomId).add({
      'forUser': forUser,
      'title': title,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'addToList': addToList,
      'locallyScheduled': locallyScheduled,
      'done': false,
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
  }) async {
    if (testMode) return;
    final data = <String, dynamic>{
      if (title != null) 'title': title,
      if (scheduledAt != null) 'scheduledAt': Timestamp.fromDate(scheduledAt),
      if (done != null) 'done': done,
      if (subtasks != null) 'subtasks': subtasks,
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
  /// shared-doc set. Applies remote title/done/dueDate changes to linked
  /// tasks and — when [applyDeletes] is true (server-confirmed snapshot) —
  /// removes local copies whose doc has been deleted by the other side.
  /// Returns true if the stored list changed.
  static Future<bool> applySharedSnapshot(
    SharedPreferences prefs,
    List<SharedTask> docs, {
    required bool applyDeletes,
  }) async {
    final raw = prefs.getString(_todosKey);
    if (raw == null) return false;
    final list = jsonDecode(raw) as List;
    final byId = {for (final d in docs) d.id: d};
    bool changed = false;
    final removed = <Map>[];

    for (final e in list) {
      final m = e as Map;
      final localId = m['id'] as String;
      var sid = m['sharedId'] as String?;
      // Legacy entries (pre-sync) created on the recipient side carry the doc
      // ID inside their local ID — backfill the link.
      if (sid == null && localId.startsWith('reminder_')) {
        sid = localId.substring('reminder_'.length);
        m['sharedId'] = sid;
        changed = true;
      }
      if (sid == null) continue; // not a shared task

      final doc = byId[sid];
      if (doc == null) {
        if (applyDeletes) removed.add(m);
        continue;
      }

      if (m['title'] != doc.title) {
        m['title'] = doc.title;
        changed = true;
      }
      if (doc.done != null && (m['done'] as bool? ?? false) != doc.done) {
        m['done'] = doc.done;
        changed = true;
      }
      // Sub-tasks: last-write-wins on the whole list. null means the doc
      // predates subtask-sync — leave the local copy untouched.
      if (doc.subtasks != null &&
          !_subtasksEqual(m['subtasks'] as List?, doc.subtasks!)) {
        m['subtasks'] = doc.subtasks;
        changed = true;
      }
      // Due date: only synced onto tasks that already track one. The creator
      // may have declined "Remind me" — their copy has no dueDate and must
      // not start firing notifications because the other side changed the time.
      final localDue = m['dueDate'] as String?;
      if (localDue != null &&
          DateTime.parse(localDue) != doc.scheduledAt) {
        m['dueDate'] = doc.scheduledAt.toIso8601String();
        changed = true;
        await _cancelNotificationsFor(localId, sid);
        if (!(m['done'] as bool? ?? false) &&
            doc.scheduledAt.isAfter(DateTime.now())) {
          await NotificationService.scheduleReminder(
            id: localId.hashCode,
            title: doc.title,
            scheduledTime: doc.scheduledAt,
          );
        }
      }
    }

    for (final m in removed) {
      changed = true;
      await _cancelNotificationsFor(m['id'] as String, m['sharedId'] as String);
      list.remove(m);
    }

    if (changed) await prefs.setString(_todosKey, jsonEncode(list));
    return changed;
  }

  /// Value-compare a local subtask list (raw prefs maps) against a doc's, by
  /// id/title/done in order — so an identical set never triggers a needless
  /// rewrite (which would loop the two devices).
  static bool _subtasksEqual(List? local, List<Map<String, dynamic>> doc) {
    final a = local ?? const [];
    if (a.length != doc.length) return false;
    for (var i = 0; i < doc.length; i++) {
      final l = a[i] as Map;
      final r = doc[i];
      if (l['id'] != r['id'] ||
          l['title'] != r['title'] ||
          (l['done'] as bool? ?? false) != (r['done'] as bool? ?? false)) {
        return false;
      }
    }
    return true;
  }

  /// A shared task may have a notification scheduled under either the local
  /// todo ID hash (self-set via the alarm button) or the doc-ID hash (set by
  /// the FCM/WorkManager delivery path) — cancel both.
  static Future<void> _cancelNotificationsFor(String localId, String sid) async {
    await NotificationService.cancelReminder(localId.hashCode);
    await NotificationService.cancelReminder(sid.hashCode.abs() % 0x7FFFFFFF);
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
    return snap.docs.map((d) {
      final data = d.data();
      return PendingReminder(
        id: d.id,
        title: (data['title'] as String?)?.trim().isNotEmpty == true
            ? data['title'] as String
            : 'Reminder',
        scheduledAt: (data['scheduledAt'] as Timestamp).toDate(),
        addToList: (data['addToList'] as bool?) ?? false,
      );
    }).toList();
  }

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
            .map((c) {
              final data = c.doc.data()!;
              return PendingReminder(
                id: c.doc.id,
                title: (data['title'] as String?)?.trim().isNotEmpty == true
                    ? data['title'] as String
                    : 'Reminder',
                scheduledAt: (data['scheduledAt'] as Timestamp).toDate(),
                addToList: (data['addToList'] as bool?) ?? false,
              );
            }));
  }

  static const _todosKey = 'todos_v1';

  /// Insert a reminder as a todo task into SharedPreferences.
  /// Guards against duplicates so it's safe to call from both the foreground
  /// stream handler and the background FCM/WorkManager worker.
  static Future<void> insertTodoToPrefs(
      SharedPreferences prefs, PendingReminder r) async {
    final raw = prefs.getString(_todosKey);
    final list = raw != null ? jsonDecode(raw) as List : <dynamic>[];
    final guardId = 'reminder_${r.id}';
    if (list.any((e) => (e as Map)['id'] == guardId)) return;
    list.insert(0, {
      'id': guardId,
      'sharedId': r.id,
      'title': r.title,
      'done': false,
      'dueDate': r.scheduledAt.toIso8601String(),
      'subtasks': <dynamic>[],
    });
    await prefs.setString(_todosKey, jsonEncode(list));
  }
}
