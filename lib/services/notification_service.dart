import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 0;

  static Future<void> initialize() async {
    if (kIsWeb) return; // ponytail: no web notifications; add the Notification API if the web app needs them.
    try {
      _ready = await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              linux: LinuxInitializationSettings(defaultActionName: 'Öffnen'),
              macOS: DarwinInitializationSettings(),
              windows: WindowsInitializationSettings(
                appName: 'AI Agent Ampel',
                appUserModelId: 'dev.nairolf.tokentracker',
                guid: '5b1a3c7e-6f1d-4c53-9a35-0f2d8b6e4a11',
              ),
            ),
          ) ??
          false;
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  static Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _id++,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'ampel_status',
            'Ampel-Status',
            importance: Importance.high,
            priority: Priority.high,
          ),
          linux: LinuxNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Notification failed: $e');
    }
  }
}
