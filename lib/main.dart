import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/todo_screen.dart';
import 'services/notification_service.dart';
import 'services/device_service.dart';
import 'services/log_service.dart';
import 'services/remote_config_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
