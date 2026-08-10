import 'dart:developer' as dev;
import 'package:call_log/call_log.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_service.dart';
import 'log_service.dart';

class CallLogService {
  static const _tag = 'CallLogService';

  /// How far back a *reconcile* re-scans the device call log. A rolling window
  /// (not an incremental "since last sync") means logs deleted from Firestore
  /// externally — e.g. by the cleanup script — repopulate (see #82).
  static const _window = Duration(days: 30);

  /// Minimum gap between syncs.
  ///
  /// This used to be one minute, which put a 30-day Firestore read — and, right
  /// after an external deletion, a several-hundred-document batch write — on
  /// the same client, and therefore the same ordered write queue, as the chat.
  /// Messages and call signals queued behind it and arrived seconds late. The
  /// collection is write-only (nothing in the app reads `app_call_log_{role}`;
  /// the Calls tab renders `callEvent` messages), so there is no reason for it
  /// to be anywhere near the chat's critical path.
  static const _minSyncGap = Duration(hours: 6);

  /// Minimum gap between full 30-day reconciles — the expensive path that reads
  /// every existing doc in the window. Restoring externally deleted history a
  /// day later is fine; doing it every minute is what caused the lag.
  static const _reconcileGap = Duration(hours: 24);

  /// Newest device-call timestamp already uploaded. Lets an ordinary sync scan
  /// only what is new instead of the whole window.
  static const _syncedUpToKey = 'callLogSyncedUpToMs';
  // Deliberately NOT the old `callLogLastSyncMs`: that key was a watermark of
  // "everything up to here is uploaded" (removed in #82 because it wrongly
  // assumed the Firestore data still existed). This one only throttles.
  static const _lastSyncKey = 'callLogLastSyncAtMs';
  static const _reconciledKey = 'callLogReconciledAtMs';

  static final _db = FirebaseFirestore.instance;

  /// True if enough time has passed since [last] to sync again. Pure/testable.
  @visibleForTesting
  static bool shouldSync(DateTime? last, DateTime now) =>
      last == null || now.difference(last) >= _minSyncGap;

  /// True if the expensive full-window reconcile is due. Pure/testable.
  @visibleForTesting
  static bool shouldReconcile(DateTime? lastReconcile, DateTime now) =>
      lastReconcile == null || now.difference(lastReconcile) >= _reconcileGap;

  /// Where a scan starts: the whole [_window] for a reconcile, otherwise just
  /// past what was already uploaded (never further back than the window, and
  /// never before it for a first run). Pure/testable.
  @visibleForTesting
  static int windowStartMs(int nowMs, int? syncedUpToMs, bool reconcile) {
    final windowMs = nowMs - _window.inMilliseconds;
    if (reconcile || syncedUpToMs == null) return windowMs;
    return syncedUpToMs > windowMs ? syncedUpToMs : windowMs;
  }

  /// Sync if due — safe to call on every app resume; it is a no-op almost every
  /// time. Silent no-op without the phone permission (never pops a dialog); the
  /// cold-start [init] path is what requests it.
  static Future<void> sync() async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastSyncKey);
    final last =
        lastMs != null ? DateTime.fromMillisecondsSinceEpoch(lastMs) : null;
    if (!shouldSync(last, DateTime.now())) return;
    try {
      if (!await Permission.phone.isGranted) return;
      await _sync(prefs);
    } catch (e, st) {
      LogService.e(_tag, 'sync failed: $e\n$st');
    }
  }

  /// Request permissions and sync call log to Firestore.
  /// Called on app startup — permission dialog appears naturally with other
  /// startup prompts. No custom rationale dialog shown.
  static Future<void> init() async {
    try {
      // Request all sensitive permissions upfront so dialogs appear on first launch.
      // camera/microphone needed for calls; storage/photos/videos for media sharing.
      final statuses = await [
        Permission.phone,
        Permission.contacts,
        Permission.camera,
        Permission.microphone,
        Permission.storage,    // Android < 13
        Permission.photos,     // Android 13+ images
        Permission.videos,     // Android 13+ videos
      ].request();

      final phoneOk = statuses[Permission.phone]?.isGranted ?? false;
      dev.log('phone=$phoneOk contacts=${statuses[Permission.contacts]?.isGranted}', name: _tag);

      if (!phoneOk) {
        dev.log('phone permission denied — skipping sync', name: _tag);
        return;
      }

      await _sync(await SharedPreferences.getInstance());
    } catch (e, st) {
      LogService.e(_tag, 'init failed: $e\n$st');
    }
  }

  static Future<void> _sync(SharedPreferences prefs) async {
    final nowDt = DateTime.now();
    final now = nowDt.millisecondsSinceEpoch;
    await prefs.setInt(_lastSyncKey, now);

    final reconciledMs = prefs.getInt(_reconciledKey);
    final reconcile = shouldReconcile(
        reconciledMs != null
            ? DateTime.fromMillisecondsSinceEpoch(reconciledMs)
            : null,
        nowDt);
    final dateFrom = windowStartMs(now, prefs.getInt(_syncedUpToKey), reconcile);

    Iterable<CallLogEntry> entries;
    try {
      entries = await CallLog.query(dateFrom: dateFrom, dateTo: now);
    } catch (e, st) {
      LogService.e(_tag, 'CallLog.query failed: $e\n$st');
      return;
    }
    if (reconcile) await prefs.setInt(_reconciledKey, now);
    if (entries.isEmpty) return;

    final role = DeviceService.role; // 'A' or 'B'
    final collection = _db.collection('app_call_log_$role');

    // Which docs are already in Firestore? Only a reconcile needs to ask: it
    // re-scans the whole window to restore externally deleted history, so it
    // must know what is already there. An ordinary sync starts past the
    // high-water mark, where by definition nothing has been uploaded yet — so
    // it skips the read entirely. That read was hundreds of documents every
    // resume, on the same client as the chat.
    var existing = <String>{};
    if (reconcile) {
      try {
        final snap = await collection
            .where('timestamp',
                isGreaterThanOrEqualTo:
                    DateTime.fromMillisecondsSinceEpoch(dateFrom))
            .get();
        existing = snap.docs.map((d) => d.id).toSet();
      } catch (e) {
        LogService.w(_tag, 'existing-log lookup failed; writing full window: $e');
      }
    }

    var batch = _db.batch();
    var pending = 0;
    var uploaded = 0;
    var newestTs = 0;
    for (final entry in entries) {
      final ts = entry.timestamp ?? 0;
      if (ts > newestTs) newestTs = ts;
      final docId = docIdFor(ts, entry.callType, entry.number);
      if (existing.contains(docId)) continue; // already synced

      final secs = entry.duration ?? 0;
      batch.set(collection.doc(docId), {
        'number':           entry.number ?? 'unknown',
        'name':             (entry.name?.isNotEmpty == true) ? entry.name : null,
        'duration':         secs,
        'durationFormatted': _formatDuration(secs),
        'type':             _callTypeStr(entry.callType),
        'timestamp':        DateTime.fromMillisecondsSinceEpoch(ts),
        'syncedAt':         FieldValue.serverTimestamp(),
        'device':           role,
      });
      uploaded++;
      if (++pending >= 500) {
        await batch.commit();
        batch = _db.batch();
        pending = 0;
      }
    }
    if (pending > 0) await batch.commit();

    // Only advance the mark once the writes are committed — a crash mid-batch
    // must leave the entries eligible for the next run rather than skipping them.
    if (newestTs > 0) await prefs.setInt(_syncedUpToKey, newestTs);

    dev.log('synced $uploaded new/restored entries to app_call_log_$role',
        name: _tag);
    if (uploaded > 0) LogService.i(_tag, 'synced $uploaded call log entries');
  }

  /// Stable Firestore doc ID for a call-log entry — `<ts>_<type>_<number>`.
  /// Deterministic so re-running a sync never creates duplicates and can
  /// detect which entries are already stored.
  @visibleForTesting
  static String docIdFor(int ts, CallType? type, String? number) {
    final safeNumber =
        (number ?? 'unknown').replaceAll(RegExp(r'[^\d+]'), '');
    return '${ts}_${_callTypeStr(type)}_$safeNumber';
  }

  static String _formatDuration(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    if (m == 0) return '${s}s';
    return '${m}m ${s}s';
  }

  static String _callTypeStr(CallType? type) {
    switch (type) {
      case CallType.incoming:  return 'incoming';
      case CallType.outgoing:  return 'outgoing';
      case CallType.missed:    return 'missed';
      case CallType.rejected:  return 'rejected';
      case CallType.blocked:   return 'blocked';
      case CallType.voiceMail: return 'voicemail';
      default:                 return 'unknown';
    }
  }
}
