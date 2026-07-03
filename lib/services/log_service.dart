import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class LogEntry {
  final String level;
  final String tag;
  final String message;
  final DateTime time;

  const LogEntry({
    required this.level,
    required this.tag,
    required this.message,
    required this.time,
  });

  @override
  String toString() =>
      '${time.toIso8601String().substring(11, 23)} $level $tag: $message';
}

class LogService {
  static final _db = FirebaseFirestore.instance;
  static CollectionReference get _col => _db.collection('app_logs');

  static String _deviceId = '';

  // Set to true in tests to skip Firestore writes.
  static bool testMode = false;

  // Controlled via Remote Config key 'enable_firestore_logging'.
  // Off by default — turned on remotely when debugging is needed.
  // Set by RemoteConfigService.init() after the first fetch.
  static bool firestoreLoggingEnabled = false;

  // In-memory log buffer for LogScreen
  static final List<LogEntry> logs = [];
  static final ValueNotifier<int> notifier = ValueNotifier(0);

  static void setDeviceId(String id) => _deviceId = id;

  static void i(String tag, String msg) => _send('INFO', tag, msg);
  static void w(String tag, String msg) => _send('WARN', tag, msg);
  static void e(String tag, String msg) => _send('ERROR', tag, msg);

  static void clear() {
    logs.clear();
    notifier.value++;
  }

  static void _send(String level, String tag, String msg) {
    debugPrint('$level/$tag: $msg');
    logs.add(LogEntry(level: level, tag: tag, message: msg, time: DateTime.now()));
    notifier.value++;
    if (testMode || !firestoreLoggingEnabled) return;
    // Fire-and-forget — never block the caller
    _col.add({
      'device': _deviceId,
      'level': level,
      'tag': tag,
      'message': msg,
      'time': FieldValue.serverTimestamp(),
    }).catchError((dynamic _) => _col.doc());
  }
}
