import 'dart:developer' as dev;
import 'package:call_log/call_log.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:permission_handler/permission_handler.dart';
import 'device_service.dart';
import 'log_service.dart';

class CallLogService {
  static const _tag = 'CallLogService';

  /// How far back each sync re-scans the device call log. A rolling window (not
  /// an incremental "since last sync") means logs deleted from Firestore
  /// externally — e.g. by the cleanup script — repopulate on the next sync.
  static const _window = Duration(days: 30);
  static final _db = FirebaseFirestore.instance;

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

      await _sync();
    } catch (e, st) {
      LogService.e(_tag, 'init failed: $e\n$st');
    }
  }

  static Future<void> _sync() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final dateFrom = now - _window.inMilliseconds;

    Iterable<CallLogEntry> entries;
    try {
      entries = await CallLog.query(dateFrom: dateFrom, dateTo: now);
    } catch (e, st) {
      LogService.e(_tag, 'CallLog.query failed: $e\n$st');
      return;
    }
    if (entries.isEmpty) return;

    final role = DeviceService.role; // 'A' or 'B'
    final collection = _db.collection('app_call_log_$role');

    // Which docs are already in Firestore for this window? Uploading only the
    // missing ones keeps a normal sync cheap (writes just new calls) while
    // restoring anything that was deleted externally. If the lookup fails
    // (e.g. offline) we fall back to writing the whole window — idempotent,
    // since doc IDs are stable.
    var existing = <String>{};
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

    var batch = _db.batch();
    var pending = 0;
    var uploaded = 0;
    for (final entry in entries) {
      final ts = entry.timestamp ?? 0;
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
