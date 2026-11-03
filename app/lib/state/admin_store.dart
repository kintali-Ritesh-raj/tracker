import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/realtime.dart';

/// Live view of the workforce for admin devices.
///
/// Loads employees over REST, then applies `location.updated` / `employee.status`
/// events from the WebSocket so markers move as soon as a phone reports a fix.
/// A periodic refresh lets the server re-derive time-based statuses (offline).
class AdminStore extends ChangeNotifier {
  AdminStore(this.api, this.realtime);

  final ApiClient api;
  final RealtimeConnection realtime;

  final Map<int, Employee> _employees = {};
  List<Team> teams = [];
  List<Site> sites = [];
  int pendingRequests = 0;
  bool loading = true;
  String? error;
  DateTime? lastSync;
  SocketState socket = SocketState.disconnected;
  bool online = true;

  final _requestEvents = StreamController<LocationRequest>.broadcast();
  Stream<LocationRequest> get requestUpdates => _requestEvents.stream;

  final List<StreamSubscription> _subs = [];
  Timer? _refresh;

  List<Employee> get employees {
    final list = _employees.values.where((e) => e.active).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  Employee? byId(int id) => _employees[id];

  StatusCounts get counts => StatusCounts.of(employees);

  /// Only real fixes: employees that share continuously or answered a request.
  List<Employee> get mapEmployees => employees
      .where((e) => e.lastLocation != null && (e.sharingEnabled || e.lastLocation!.source == 'request'))
      .toList();

  Future<void> start() async {
    _subs.add(realtime.events.listen(_onEvent));
    _subs.add(realtime.states.listen((s) {
      final wasDown = socket != SocketState.connected;
      socket = s;
      // Catch up on anything missed while the socket was down.
      if (s == SocketState.connected && wasDown && lastSync != null) refresh();
      notifyListeners();
    }));
    _subs.add(Connectivity().onConnectivityChanged.listen((results) {
      final nowOnline = !results.contains(ConnectivityResult.none);
      if (nowOnline && !online) {
        realtime.reconnectNow();
        refresh();
      }
      online = nowOnline;
      notifyListeners();
    }));
    realtime.connect();
    _refresh = Timer.periodic(const Duration(seconds: 60), (_) => refresh(quiet: true));
    await refresh();
  }

  Future<void> refresh({bool quiet = false}) async {
    if (!quiet) {
      loading = _employees.isEmpty;
      notifyListeners();
    }
    try {
      final results = await Future.wait([
        api.get('/employees'),
        api.get('/teams'),
        api.get('/sites'),
        api.get('/dashboard'),
      ]);
      _employees
        ..clear()
        ..addEntries((results[0] as List).map((j) {
          final e = Employee.fromJson(j as Map<String, dynamic>);
          return MapEntry(e.id, e);
        }));
      teams = (results[1] as List).map((j) => Team.fromJson(j as Map<String, dynamic>)).toList();
      sites = (results[2] as List).map((j) => Site.fromJson(j as Map<String, dynamic>)).toList();
      pendingRequests = (results[3] as Map<String, dynamic>)['pending_requests'] as int;
      lastSync = DateTime.now();
      error = null;
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void upsert(Employee employee) {
    _employees[employee.id] = employee;
    notifyListeners();
  }

  void remove(int id) {
    _employees.remove(id);
    notifyListeners();
  }

  void _onEvent(RealtimeEvent event) {
    switch (event.type) {
      case 'location.updated':
      case 'employee.status':
        final e = Employee.fromJson(event.data);
        _employees[e.id] = e;
        lastSync = DateTime.now();
        notifyListeners();
      case 'employee.deleted':
        remove(event.data['id'] as int);
      case 'location_request.created':
      case 'location_request.updated':
        final req = LocationRequest.fromJson(event.data);
        _requestEvents.add(req);
        // Pending count drives the dashboard badge; recompute cheaply from the server.
        api.get('/dashboard').then((d) {
          pendingRequests = (d as Map<String, dynamic>)['pending_requests'] as int;
          notifyListeners();
        }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _refresh?.cancel();
    _requestEvents.close();
    super.dispose();
  }
}
