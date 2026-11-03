import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum DeviceRole { admin, employee }

/// The paired identity of this phone. The device token lives in Android
/// Keystore-backed storage and is never shown in the UI.
class Session {
  Session({
    required this.serverUrl,
    required this.token,
    required this.role,
    required this.deviceId,
    this.employeeId,
  });

  final String serverUrl;
  final String token;
  final DeviceRole role;
  final int deviceId;
  final int? employeeId;

  bool get isAdmin => role == DeviceRole.admin;

  Uri api(String path, [Map<String, String>? query]) {
    final base = Uri.parse(serverUrl);
    return base.replace(
      path: '${base.path.replaceAll(RegExp(r'/$'), '')}/api/v1$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Uri get websocket {
    final http = api('/ws');
    return http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
  }
}

class SessionStore {
  static const _storage = FlutterSecureStorage();

  static Future<Session?> load() async {
    final values = await _storage.readAll();
    final token = values['token'];
    final url = values['server_url'];
    final role = values['role'];
    final deviceId = int.tryParse(values['device_id'] ?? '');
    if (token == null || url == null || role == null || deviceId == null) {
      return null;
    }
    return Session(
      serverUrl: url,
      token: token,
      role: role == 'admin' ? DeviceRole.admin : DeviceRole.employee,
      deviceId: deviceId,
      employeeId: int.tryParse(values['employee_id'] ?? ''),
    );
  }

  static Future<void> save(Session session) async {
    await _storage.write(key: 'server_url', value: session.serverUrl);
    await _storage.write(key: 'token', value: session.token);
    await _storage.write(key: 'role', value: session.role.name);
    await _storage.write(key: 'device_id', value: '${session.deviceId}');
    if (session.employeeId != null) {
      await _storage.write(key: 'employee_id', value: '${session.employeeId}');
    } else {
      await _storage.delete(key: 'employee_id');
    }
  }

  static Future<void> clear() => _storage.deleteAll();
}
