import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter/material.dart';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  try {
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'wayrouter_foreground',
        initialNotificationTitle: 'WayRouter — Standby',
        initialNotificationContent: 'Waiting for motion to activate GPS...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  } catch (e) {
    debugPrint('Error initializing background service: $e');
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });

    // Listen for motion state updates sent from the main isolate
    service.on('motionState').listen((event) async {
      if (event == null) return;
      final state = event['state'] as String? ?? 'stationary';
      final lastSync = event['lastSync'] as String? ?? '--';

      String icon;
      switch (state) {
        case 'driving':
          icon = '🚗';
          break;
        case 'walking':
          icon = '🚶';
          break;
        default:
          icon = '⏸';
      }

      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: 'WayRouter $icon ${state.toUpperCase()}',
          content: 'Last sync: $lastSync',
        );
      }
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Heartbeat — keeps foreground service alive
  Timer.periodic(const Duration(seconds: 15), (timer) async {
    if (service is AndroidServiceInstance) {
      if (!await service.isForegroundService()) {
        timer.cancel();
      }
    }
  });
}
