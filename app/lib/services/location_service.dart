import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';

/// What the phone currently allows. Each false value maps to a fix-it row in
/// the employee UI.
class LocationHealth {
  const LocationHealth({
    required this.servicesEnabled,
    required this.foreground,
    required this.background,
    required this.notifications,
    required this.batteryUnrestricted,
    required this.precise,
  });

  final bool servicesEnabled;
  final bool foreground;
  final bool background;
  final bool notifications;
  final bool batteryUnrestricted;
  final bool precise;

  bool get canTrack => servicesEnabled && foreground;
  bool get allGood => canTrack && background && notifications && batteryUnrestricted && precise;

  Map<String, dynamic> toJson() => {
        'services_enabled': servicesEnabled,
        'foreground': foreground,
        'background': background,
        'notifications': notifications,
        'battery_unrestricted': batteryUnrestricted,
        'precise': precise,
      };
}

/// Fix converted to the backend's `Fix` schema.
Map<String, dynamic> fixFromPosition(Position p, {String source = 'stream'}) => {
      'latitude': p.latitude,
      'longitude': p.longitude,
      'accuracy_m': p.accuracy,
      'altitude_m': p.altitude,
      'speed_mps': p.speed < 0 ? null : p.speed,
      'heading': p.heading < 0 || p.heading > 360 ? null : p.heading,
      'recorded_at': p.timestamp.toUtc().toIso8601String(),
      'source': source,
      'is_mocked': p.isMocked,
    };

class LocationService {
  static Future<LocationHealth> health() async {
    final services = await Geolocator.isLocationServiceEnabled();
    final perm = await Geolocator.checkPermission();
    final accuracy = perm == LocationPermission.denied || perm == LocationPermission.deniedForever
        ? LocationAccuracyStatus.reduced
        : await Geolocator.getLocationAccuracy();
    return LocationHealth(
      servicesEnabled: services,
      foreground: perm == LocationPermission.always || perm == LocationPermission.whileInUse,
      background: perm == LocationPermission.always,
      notifications: await Permission.notification.isGranted,
      batteryUnrestricted: await Permission.ignoreBatteryOptimizations.isGranted,
      precise: accuracy == LocationAccuracyStatus.precise,
    );
  }

  /// Android requires asking for foreground location before background.
  static Future<bool> requestForeground() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return false;
    }
    return perm == LocationPermission.whileInUse || perm == LocationPermission.always;
  }

  static Future<bool> requestBackground() async {
    if (!await requestForeground()) return false;
    final status = await Permission.locationAlways.request();
    if (status.isPermanentlyDenied) await openAppSettings();
    return status.isGranted;
  }

  static Future<void> requestNotifications() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) await openAppSettings();
  }

  static Future<void> requestBatteryExemption() => Permission.ignoreBatteryOptimizations.request();

  static Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  /// One high-accuracy fix. Falls back to the last known position only if it is
  /// recent; its real timestamp is sent so the server and admins can judge it.
  static Future<Position?> currentFix({Duration timeout = const Duration(seconds: 25)}) async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(accuracy: LocationAccuracy.best, timeLimit: timeout),
      );
    } on TimeoutException {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && DateTime.now().difference(last.timestamp) < const Duration(minutes: 5)) return last;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Approves a location request with a fresh fix. Returns an error message or null.
  static Future<String?> answerRequest(ApiClient api, int requestId) async {
    final fix = await currentFix();
    if (fix == null) return 'Could not get a GPS fix. Move near a window or outdoors and try again.';
    try {
      await api.post('/location-requests/$requestId/respond', {
        'decision': 'approve',
        'fix': fixFromPosition(fix, source: 'request'),
      });
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
}

/// Fixes waiting to be uploaded. Survives app restarts so nothing recorded
/// while offline is lost; capped so a phone offline for days cannot fill up.
class FixOutbox {
  static const _key = 'fix_outbox_v1';
  static const maxSize = 500;

  static Future<List<Map<String, dynamic>>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> write(List<Map<String, dynamic>> fixes) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = fixes.length > maxSize ? fixes.sublist(fixes.length - maxSize) : fixes;
    await prefs.setString(_key, jsonEncode(trimmed));
  }

  static Future<int> add(Map<String, dynamic> fix) async {
    final all = await read()
      ..add(fix);
    await write(all);
    return all.length;
  }

  static Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_key);
}

enum TrackerState { stopped, starting, tracking, waitingForGps, error }

/// Continuous location sharing for employee phones.
///
/// Uses the fused provider through geolocator with a foreground-service
/// notification, so Android keeps delivering fixes with the screen off.
class LocationTracker extends ChangeNotifier {
  LocationTracker(this.api);

  final ApiClient api;

  TrackerState state = TrackerState.stopped;
  Position? lastFix;
  DateTime? lastUploadAt;
  int queued = 0;
  String? problem;
  bool online = true;

  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _serviceSub;
  StreamSubscription? _connectivitySub;
  Timer? _heartbeat;
  Timer? _gpsWatchdog;
  bool _flushing = false;

  bool get isRunning => state != TrackerState.stopped;

  Future<void> start({required int intervalSeconds, required int distanceFilterM}) async {
    if (isRunning) await stop();
    state = TrackerState.starting;
    problem = null;
    notifyListeners();

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilterM,
      intervalDuration: Duration(seconds: intervalSeconds),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'SLG FieldTrack is sharing your location',
        notificationText: 'Visible to SLG management while you are on duty. Open the app to pause.',
        notificationChannelName: 'Location sharing',
        enableWakeLock: true,
        setOngoing: true,
        color: Color(0xFFF97316),
      ),
    );
    _positions = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e) {
        state = TrackerState.error;
        problem = e is LocationServiceDisabledException
            ? 'Location is turned off. Turn it on to keep sharing.'
            : 'Location updates stopped: $e';
        notifyListeners();
      },
    );
    _serviceSub = Geolocator.getServiceStatusStream().listen((s) {
      if (s == ServiceStatus.disabled) {
        state = TrackerState.error;
        problem = 'Location is turned off. Turn it on to keep sharing.';
      } else if (state == TrackerState.error) {
        state = TrackerState.waitingForGps;
        problem = null;
      }
      notifyListeners();
    });
    _connectivitySub = Connectivity().onConnectivityChanged.listen((r) {
      online = !r.contains(ConnectivityResult.none);
      notifyListeners();
      if (online) flush();
    });
    _heartbeat = Timer.periodic(const Duration(minutes: 5), (_) => sendHeartbeat());
    _armWatchdog(intervalSeconds);
    state = TrackerState.waitingForGps;
    notifyListeners();
    unawaited(sendHeartbeat());
    unawaited(flush());
  }

  /// If no fix arrives for 3 intervals, tell the employee GPS is weak instead of
  /// silently showing an old position as current.
  void _armWatchdog(int intervalSeconds) {
    _gpsWatchdog?.cancel();
    final window = Duration(seconds: (intervalSeconds * 3).clamp(90, 900));
    _gpsWatchdog = Timer.periodic(const Duration(seconds: 30), (_) {
      final last = lastFix?.timestamp;
      if (state == TrackerState.tracking && last != null && DateTime.now().difference(last) > window) {
        state = TrackerState.waitingForGps;
        notifyListeners();
      }
    });
  }

  Future<void> _onPosition(Position p) async {
    lastFix = p;
    state = TrackerState.tracking;
    problem = p.isMocked ? 'A mock-location app is active. SLG only accepts real GPS positions.' : null;
    notifyListeners();
    if (p.isMocked) return;
    queued = await FixOutbox.add(fixFromPosition(p));
    notifyListeners();
    await flush();
  }

  /// Uploads queued fixes oldest-first in batches of 100.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      var pending = await FixOutbox.read();
      while (pending.isNotEmpty) {
        final batch = pending.take(100).toList();
        try {
          await api.post('/locations', {'fixes': batch});
        } on ApiException catch (e) {
          if (e.statusCode == 422 || e.statusCode == 403) {
            // 403: sharing turned off server-side; 422: malformed. Drop, don't retry forever.
            await FixOutbox.write(pending.skip(batch.length).toList());
            pending = await FixOutbox.read();
            if (e.statusCode == 403) {
              problem = e.message;
              break;
            }
            continue;
          }
          online = !e.isNetwork;
          break; // network/server trouble — keep the queue, retry later
        }
        pending = pending.skip(batch.length).toList();
        await FixOutbox.write(pending);
        lastUploadAt = DateTime.now();
        online = true;
      }
      queued = pending.length;
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  Future<void> sendHeartbeat() async {
    try {
      final h = await LocationService.health();
      int? battery;
      try {
        battery = await Battery().batteryLevel;
      } catch (_) {}
      await api.post('/devices/heartbeat', {
        'battery_level': battery,
        'permission_state': {...h.toJson(), 'tracking': state.name, 'queued': queued},
      });
    } catch (_) {
      // Heartbeats are best-effort.
    }
  }

  Future<void> stop() async {
    await _positions?.cancel();
    await _serviceSub?.cancel();
    await _connectivitySub?.cancel();
    _heartbeat?.cancel();
    _gpsWatchdog?.cancel();
    _positions = null;
    state = TrackerState.stopped;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
