import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import 'location_service.dart';

/// Push messages that matter to the app.
class PushMessage {
  PushMessage(this.type, this.requestId);
  final String type; // location_request | location_refresh
  final int? requestId;
}

/// Runs in a background isolate when a data message arrives while the app is
/// not in the foreground. For consented continuous sharing, the server sends a
/// silent `location_refresh`; we answer it with a fresh fix without UI.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.data['type'] != 'location_refresh') return;
  final requestId = int.tryParse('${message.data['request_id']}');
  final session = await SessionStore.load();
  if (requestId == null || session == null || session.isAdmin) return;
  await LocationService.answerRequest(ApiClient(session), requestId);
}

/// Firebase Cloud Messaging wrapper. FCM is optional: when the app is built
/// without google-services.json, [enabled] is false and the app relies on its
/// WebSocket connection while open.
class PushService {
  static bool enabled = false;
  static final _local = FlutterLocalNotificationsPlugin();
  static final _messages = StreamController<PushMessage>.broadcast();

  static Stream<PushMessage> get messages => _messages.stream;

  static const requestChannel = AndroidNotificationChannel(
    'location_requests',
    'Location requests',
    description: 'When SLG management asks for your current location',
    importance: Importance.high,
  );

  static Future<void> initialize() async {
    await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) {
        final id = int.tryParse(r.payload ?? '');
        _messages.add(PushMessage('location_request', id));
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(requestChannel);

    try {
      await Firebase.initializeApp();
      enabled = true;
    } catch (e) {
      debugPrint('FCM disabled (no Firebase config): $e');
      return;
    }
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    FirebaseMessaging.onMessage.listen(_onForeground);
    FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _onOpened(initial);
  }

  static PushMessage _parse(RemoteMessage m) =>
      PushMessage(m.data['type'] as String? ?? '', int.tryParse('${m.data['request_id']}'));

  static void _onForeground(RemoteMessage m) => _messages.add(_parse(m));

  static void _onOpened(RemoteMessage m) => _messages.add(_parse(m));

  /// Shows a local notification (used when a request arrives over the socket
  /// while the app is in the background but still alive).
  static Future<void> showRequestNotification(int requestId) => _local.show(
        id: requestId,
        title: 'Location requested',
        body: 'SLG management asked for your current location. Tap to respond.',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            requestChannel.id,
            requestChannel.name,
            channelDescription: requestChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: '$requestId',
      );

  /// Sends this phone's FCM token to the backend so it can be reached.
  static Future<void> registerDevice(ApiClient api) async {
    if (!enabled) return;
    try {
      await FirebaseMessaging.instance.requestPermission();
      // The backend sends with firebase-admin to registration tokens, so we keep
      // the token API rather than the newer installation-ID (FID) direct send.
      // ignore: deprecated_member_use
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await api.post('/devices/heartbeat', {'push_token': token});
      // ignore: deprecated_member_use
      FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        api.post('/devices/heartbeat', {'push_token': t}).catchError((_) => null);
      });
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }
}
