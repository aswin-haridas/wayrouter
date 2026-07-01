import 'package:flutter/material.dart';
import 'services/background_service.dart';
import 'sensor_tracker_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Initialize Background Service
    await initializeService();
  } catch (e) {
    debugPrint("Failed to initialize background service: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WayRouter Sensor Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF43F5E),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.light,
      home: const SensorTrackerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
