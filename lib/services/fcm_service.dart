import 'dart:developer' as dev;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';
import 'notification_service.dart';
import 'reminder_service.dart';

// Top-level handler — called by the FCM plugin in a separate isolate when
// the app is backgrounded or terminated. Firebase is already initialised
// by the plugin before this function is invoked.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  if (message.data['type'] == 'reminder') {
    await _processReminderPayload(message.data);
  }
}

/// Shared logic for handling an incoming FCM reminder payload, called from
/// both the foreground [FirebaseMessaging.onMessage] listener and the
/// background isolate handler above.
Future<void> _processReminderPayload(Map<String, dynamic> data) async {
  final reminderId = data['reminderId'] as String?;
  final title = (data['title'] as String?)?.isNotEmpty == true
      ? data['title'] as String
      : 'Reminder';
  final scheduledAtStr = data['scheduledAt'] as String?;
  final addToList = data['addToList'] == 'true';

  if (reminderId == null || scheduledAtStr == null) return;

  DateTime scheduledAt;
  try {
    scheduledAt = DateTime.parse(scheduledAtStr);
  } catch (_) {
    return;
  }

  // Skip if the reminder time has already passed.
  if (scheduledAt.isBefore(DateTime.now().subtract(const Duration(minutes: 1)))) {
    return;
  }

  await NotificationService.init();

  final notifId = reminderId.hashCode.abs() % 0x7FFFFFFF;

  // Immediate confirmation — tells B right now that a reminder has been set,
  // exactly as if B had set it themselves.
  final hm = '${scheduledAt.hour.toString().padLeft(2, '0')}:'
      '${scheduledAt.minute.toString().padLeft(2, '0')}';
  final now = DateTime.now();
  final todayDate = DateTime(now.year, now.month, now.day);
  final remDate = DateTime(scheduledAt.year, scheduledAt.month, scheduledAt.day);
  final diffDays = remDate.difference(todayDate).inDays;
  final whenStr = diffDays == 0
      ? 'today at $hm'
      : diffDays == 1
          ? 'tomorrow at $hm'
          : '${scheduledAt.day}/${scheduledAt.month} at $hm';
  await NotificationService.showNow(
    id: notifId ^ 0x1000000,
    title: 'Reminder set',
    body: '$title — $whenStr',
  );

  // Schedule the local notification to fire at the exact time.
  await NotificationService.scheduleReminder(
    id: notifId,
    title: title,
    scheduledTime: scheduledAt,
  );

  if (addToList) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await ReminderService.insertTodoToPrefs(
        prefs,
        PendingReminder(
          id: reminderId,
          title: title,
          scheduledAt: scheduledAt,
          addToList: true,
        ),
      );
      // Signal TodoScreen to reload — only meaningful in the foreground path.
      todoRefreshNotifier.value++;
    } catch (_) {}
  }
}

class FcmService {
  static bool _initialized = false;
  static const _tag = 'FcmService';

  /// Call once after Firebase and NotificationService are ready.
  /// [forUser] is the local device's role ('A' or 'B').
  static Future<void> init({required String forUser}) async {
    if (_initialized) return;
    _initialized = true;

    // Must be registered before any other FirebaseMessaging call.
    FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

    final messaging = FirebaseMessaging.instance;

    await messaging.requestPermission(alert: true, badge: true, sound: true);

    // Store the FCM token in the room doc so the Cloud Function can read it.
    try {
      final token = await messaging.getToken();
      if (token != null) await _saveToken(token, forUser);
    } catch (e) {
      dev.log('token fetch failed: $e', name: _tag);
    }

    // Refresh whenever FCM rotates the token.
    messaging.onTokenRefresh.listen((token) {
      _saveToken(token, forUser).catchError(
        (e) => dev.log('token refresh save failed: $e', name: _tag),
      );
    });

    // Foreground messages — Android suppresses the auto-notification when the
    // app is in the foreground, so we handle it manually here.
    FirebaseMessaging.onMessage.listen((message) async {
      dev.log('foreground FCM: ${message.data}', name: _tag);
      if (message.data['type'] == 'reminder') {
        await _processReminderPayload(message.data);
      }
    });
  }

  static Future<void> _saveToken(String token, String forUser) async {
    await FirebaseFirestore.instance
        .collection('rooms')
        .doc(chatRoomId)
        .set({'fcmTokens': {forUser: token}}, SetOptions(merge: true));
    dev.log('token saved for $forUser', name: _tag);
  }
}
