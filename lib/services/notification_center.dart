import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ride_backend_service.dart';
import 'ride_repositories.dart';

class CenterNotification {
  const CenterNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.kind,
    this.read = false,
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final String kind;
  final bool read;

  CenterNotification copy({bool? read}) => CenterNotification(
    id: id,
    title: title,
    body: body,
    createdAt: createdAt,
    kind: kind,
    read: read ?? this.read,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'at': createdAt.toIso8601String(),
    'kind': kind,
    'read': read,
  };

  factory CenterNotification.fromJson(Map<String, dynamic> json) =>
      CenterNotification(
        id: json['id'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        createdAt:
            DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        kind: json['kind'] as String? ?? 'general',
        read: json['read'] as bool? ?? false,
      );
}

/// Receives real ride/support events from the backend layer and stores the
/// same event in the in-app inbox and (when enabled) the device notification tray.
class NotificationCenterService {
  NotificationCenterService._();
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const _storageKey = 'darb_notification_center_v1';
  static const _enabledKey = 'darb_notifications_enabled';

  static Future<void> initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_darb'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          'darb_updates',
          'تحديثات درب',
          description: 'حالة الرحلة ورسائل مركز خدمة الزبائن',
          importance: Importance.high,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          'darb_captain_requests',
          'طلبات الكابتن الفورية',
          description: 'تنبيهات فورية عند وجود طلب رحلة جديد للكابتن',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
    }
  }

  static Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? true;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    return true;
  }

  static Future<bool> enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  static Future<bool> setEnabled(bool value) async {
    if (value && !await requestPermission()) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    return true;
  }

  static Future<List<CenterNotification>> all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? const [];
    return raw
        .map((value) {
          try {
            return CenterNotification.fromJson(
              Map<String, dynamic>.from(jsonDecode(value) as Map),
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<CenterNotification>()
        .toList();
  }

  static Future<void> add({
    required String title,
    required String body,
    String kind = 'general',
  }) async {
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final entry = CenterNotification(
      id: id,
      title: title,
      body: body,
      createdAt: now,
      kind: kind,
    );
    final entries = [entry, ...await all()].take(60).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storageKey,
      entries.map((item) => jsonEncode(item.toJson())).toList(),
    );

    if (await enabled()) {
      await _plugin.show(
        now.millisecondsSinceEpoch.remainder(2147483647),
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'darb_updates',
            'تحديثات درب',
            channelDescription: 'حالة الرحلة ورسائل مركز خدمة الزبائن',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat_darb',
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: kind,
      );
    }
  }

  static Future<void> addCaptainAlert({
    required String title,
    required String body,
  }) async {
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final entry = CenterNotification(
      id: id,
      title: title,
      body: body,
      createdAt: now,
      kind: 'captain_request',
    );
    final entries = [entry, ...await all()].take(60).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storageKey,
      entries.map((item) => jsonEncode(item.toJson())).toList(),
    );

    if (await enabled()) {
      await _plugin.show(
        now.millisecondsSinceEpoch.remainder(2147483647),
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'darb_captain_requests',
            'طلبات الكابتن الفورية',
            channelDescription: 'تنبيهات فورية عند وجود طلب رحلة جديد للكابتن',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.call,
            icon: 'ic_stat_darb',
          ),
          iOS: DarwinNotificationDetails(presentSound: true),
        ),
        payload: 'captain_request',
      );
    }
  }

  static Future<void> markAllRead() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = (await all())
        .map((item) => jsonEncode(item.copy(read: true).toJson()))
        .toList();
    await prefs.setStringList(_storageKey, entries);
  }
}

/// Concrete [NotificationServiceInterface] bridging local notifications and
/// future FCM push token registration.
class AppNotificationService implements NotificationServiceInterface {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  @override
  Future<void> initialize() => NotificationCenterService.initialize();

  @override
  Future<void> notify({
    required String title,
    required String body,
    String kind = 'general',
  }) => NotificationCenterService.add(title: title, body: body, kind: kind);

  @override
  Future<void> notifyCaptainRequest({
    required String title,
    required String body,
  }) => NotificationCenterService.addCaptainAlert(title: title, body: body);

  @override
  Future<void> registerPushToken(String token) =>
      RideBackendService.instance.registerFcmToken(token);
}
