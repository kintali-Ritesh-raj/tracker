import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'session.dart';

/// Error with a message that is safe to show to the user.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;
  bool get isNetwork => statusCode == null;

  @override
  String toString() => message;
}

/// Thin JSON client over the FastAPI backend. Every call carries the device token.
class ApiClient {
  ApiClient(this.session, {http.Client? client}) : _http = client ?? http.Client();

  final Session session;
  final http.Client _http;

  /// Called when the server says this device was revoked.
  void Function()? onUnauthorized;

  static const _timeout = Duration(seconds: 15);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${session.token}',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send(() => _http.get(session.api(path, query), headers: _headers));

  Future<dynamic> post(String path, [Object? body]) => _send(() =>
      _http.post(session.api(path), headers: _headers, body: jsonEncode(body ?? {})));

  Future<dynamic> put(String path, Object body) =>
      _send(() => _http.put(session.api(path), headers: _headers, body: jsonEncode(body)));

  Future<dynamic> patch(String path, Object body) =>
      _send(() => _http.patch(session.api(path), headers: _headers, body: jsonEncode(body)));

  Future<dynamic> delete(String path) =>
      _send(() => _http.delete(session.api(path), headers: _headers));

  Future<dynamic> uploadFile(String path, String field, File file, String contentType) {
    return _send(() async {
      final request = http.MultipartRequest('POST', session.api(path))
        ..headers['Authorization'] = 'Bearer ${session.token}'
        ..files.add(await http.MultipartFile.fromPath(field, file.path,
            contentType: MediaType.parse(contentType)));
      return http.Response.fromStream(await _http.send(request));
    });
  }

  Map<String, String> get imageHeaders => {'Authorization': 'Bearer ${session.token}'};

  String photoUrl(int employeeId, int version) =>
      '${session.api('/employees/$employeeId/photo')}?v=$version';

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    final http.Response response;
    try {
      response = await call().timeout(_timeout);
    } on TimeoutException {
      throw ApiException('The server took too long to respond. Check your connection.');
    } on SocketException {
      throw ApiException('No connection to the SLG server. Check mobile data or Wi-Fi.');
    } on http.ClientException {
      throw ApiException('No connection to the SLG server. Check mobile data or Wi-Fi.');
    } on HandshakeException {
      throw ApiException('Secure connection to the server failed.');
    }
    if (response.statusCode == 401) onUnauthorized?.call();
    if (response.statusCode >= 400) {
      throw ApiException(_detail(response), statusCode: response.statusCode);
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  static String _detail(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final detail = body is Map ? body['detail'] : null;
      if (detail is String) return detail;
      if (detail is List && detail.isNotEmpty && detail.first is Map) {
        return '${detail.first['msg']}';
      }
    } catch (_) {}
    return 'Request failed (${response.statusCode}).';
  }

}
