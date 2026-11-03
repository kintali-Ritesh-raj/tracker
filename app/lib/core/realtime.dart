import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'session.dart';

class RealtimeEvent {
  RealtimeEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

enum SocketState { connecting, connected, disconnected }

/// Auto-reconnecting WebSocket to `/api/v1/ws`. The token travels in the
/// `Sec-WebSocket-Protocol` header so it never appears in server access logs.
class RealtimeConnection {
  RealtimeConnection(this.session);

  final Session session;
  final _events = StreamController<RealtimeEvent>.broadcast();
  final _state = StreamController<SocketState>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _closed = false;
  SocketState current = SocketState.disconnected;

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<SocketState> get states => _state.stream;

  void connect() {
    if (_closed || current == SocketState.connecting || current == SocketState.connected) return;
    _setState(SocketState.connecting);
    try {
      final channel = IOWebSocketChannel.connect(
        session.websocket,
        protocols: ['bearer', session.token],
        pingInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(seconds: 10),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: () {
          if (channel.closeCode == 4401) {
            // Revoked or unknown device: retrying will never succeed.
            _events.add(RealtimeEvent('unauthorized', const {}));
            _closed = true;
          }
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      channel.ready.then((_) {
        _attempt = 0;
        _setState(SocketState.connected);
      }, onError: (Object _) => _scheduleReconnect());
    } catch (_) {
      _scheduleReconnect();
    }
  }

  /// Call when connectivity returns to skip the back-off wait.
  void reconnectNow() {
    if (current == SocketState.connected) return;
    _retry?.cancel();
    _teardown();
    _setState(SocketState.disconnected);
    connect();
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String;
      if (type == 'ping') {
        _channel?.sink.add(jsonEncode({'type': 'pong'}));
        return;
      }
      _events.add(RealtimeEvent(type, (msg['data'] as Map?)?.cast<String, dynamic>() ?? {}));
    } catch (_) {
      // Ignore malformed frames.
    }
  }

  void _scheduleReconnect() {
    _teardown();
    _setState(SocketState.disconnected);
    if (_closed) return;
    // Exponential back-off with jitter, capped at 30 s.
    final seconds = min(30, pow(2, _attempt).toInt()) + Random().nextDouble();
    _attempt = min(_attempt + 1, 5);
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: (seconds * 1000).round()), connect);
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _setState(SocketState s) {
    current = s;
    if (!_state.isClosed) _state.add(s);
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _teardown();
    _events.close();
    _state.close();
  }
}
