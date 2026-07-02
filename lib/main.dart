import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/todo_screen.dart';
import 'services/notification_service.dart';
import 'services/device_service.dart';
import 'services/log_service.dart';
import 'services/remote_config_service.dart';

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
