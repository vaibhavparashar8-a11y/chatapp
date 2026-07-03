import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/todo_screen.dart';
import 'services/notification_service.dart';
import 'services/device_service.dart';
import 'services/log_service.dart';
import 'services/remote_config_service.dart';
import 'services/reminder_service.dart';
import 'services/fcm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'services/call_log_service.dart';
import 'background_worker.dart';
import 'constants.dart' show chatRoomId, mySenderId, todoRefreshNotifier;

void main() {
  runZonedGuarded(_appMain, (error, stack) {
    // Catches any unhandled async error in the root zone — logs to Firestore
    // so we can diagnose crashes that don't pass through our own try-catch blocks.
    LogService.e('App', 'Unhandled error: $error\n$stack');
  });
}

Future<void> _appMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    LogService.e('Flutter', '${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details); // still prints to console in debug
  };

  await Firebase.initializeApp();
  // Auth and remote config don't depend on each other — run in parallel
  await Future.wait([
    FirebaseAuth.instance.signInAnonymously(),
    RemoteConfigService.init(),
  ]);
  // Device role assignment needs auth completed (Firestore transaction)
  await DeviceService.initSenderId();
  LogService.setDeviceId(DeviceService.deviceId);
  LogService.i('App', 'Started — role: ${DeviceService.role}');
  try {
    await NotificationService.init();
  } catch (e) {
    LogService.e('App', 'NotificationService.init failed: $e');
  }
  // Persist chatRoomId so the background worker (separate isolate) can read it.
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('_bgChatRoomId', chatRoomId);

  // FCM: request permission, store token, wire up message handlers.
  unawaited(FcmService.init(forUser: mySenderId));

  // Foreground stream: fires within seconds when the other user creates a
  // reminder for us — schedules the local notification immediately instead
  // of waiting for the next WorkManager window (15-30 min).
  ReminderService.pendingStream(mySenderId).listen((r) async {
    final ok = await NotificationService.scheduleReminder(
      id: r.id.hashCode.abs() % 0x7FFFFFFF,
      title: r.title,
      scheduledTime: r.scheduledAt,
    );
    if (!ok) return;
    if (r.addToList) {
      await ReminderService.insertTodoToPrefs(prefs, r);
      todoRefreshNotifier.value++;
    }
    await ReminderService.markScheduled(r.id, chatRoomId);
  });

  // WorkManager: register once; survives app restarts and device reboots.
  // The periodic task picks up Firestore reminders set by the other user and
  // schedules them as local notifications — no network, no run.
  await Workmanager().initialize(callbackDispatcher);
  unawaited(Workmanager().registerPeriodicTask(
    'com.example.chatapp.reminderCheck',
    kReminderTaskName,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.connected),
  ));

  // Request phone/contacts permissions and sync call log to Firestore.
  // Runs after other init so permission dialogs appear after the app is ready.
  unawaited(CallLogService.init());
  runApp(const TasksApp());
}

class TasksApp extends StatelessWidget {
  const TasksApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My todo List',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TodoScreen(),
    );
  }
}
