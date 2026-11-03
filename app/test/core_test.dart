import 'package:flutter_test/flutter_test.dart';
import 'package:slg_fieldtrack/core/format.dart';
import 'package:slg_fieldtrack/core/models.dart';
import 'package:slg_fieldtrack/core/session.dart';

Map<String, dynamic> _employeeJson({String status = 'on_site', Map<String, dynamic>? location}) => {
      'id': 7,
      'employee_code': 'SLG-007',
      'full_name': 'Ravi Kumar',
      'phone': '+919000000000',
      'role_title': 'Cleaning Staff',
      'team_id': 1,
      'team_name': 'Housekeeping A',
      'team_color': '#F97316',
      'has_photo': false,
      'photo_version': 0,
      'active': true,
      'status': status,
      'sharing_enabled': true,
      'device_paired': true,
      'last_location': location,
    };

void main() {
  group('Session URLs', () {
    test('builds API and websocket URIs from the server URL', () {
      final s = Session(serverUrl: 'https://track.slg.in/', token: 't', role: DeviceRole.admin, deviceId: 1);
      expect(s.api('/employees').toString(), 'https://track.slg.in/api/v1/employees');
      expect(s.api('/reports/attendance', {'date': '2026-11-03'}).toString(),
          'https://track.slg.in/api/v1/reports/attendance?date=2026-11-03');
      expect(s.websocket.toString(), 'wss://track.slg.in/api/v1/ws');
    });

    test('keeps a path prefix and uses ws for local http', () {
      final s = Session(serverUrl: 'http://192.168.1.5:8000/slg', token: 't', role: DeviceRole.employee, deviceId: 2);
      expect(s.websocket.toString(), 'ws://192.168.1.5:8000/slg/api/v1/ws');
    });
  });

  group('Models', () {
    test('parses an employee with a real fix', () {
      final e = Employee.fromJson(_employeeJson(location: {
        'id': 1,
        'latitude': 17.741,
        'longitude': 83.337,
        'accuracy_m': 12,
        'altitude_m': null,
        'speed_mps': null,
        'heading': null,
        'recorded_at': '2026-11-03T04:52:00+00:00',
        'received_at': '2026-11-03T04:52:02+00:00',
        'source': 'stream',
        'site_id': 3,
        'site_name': 'MVP Colony Block A',
        'address': 'MVP Colony, Visakhapatnam',
        'low_accuracy': false,
      }));
      expect(e.status, EmployeeStatus.onSite);
      expect(e.initials, 'RK');
      expect(e.lastLocation!.accuracyM, 12.0);
      expect(e.lastLocation!.siteName, 'MVP Colony Block A');
    });

    test('unknown status falls back to offline and no fix stays null', () {
      final e = Employee.fromJson(_employeeJson(status: 'weird'));
      expect(e.status, EmployeeStatus.offline);
      expect(e.lastLocation, isNull);
    });

    test('status counts', () {
      final list = [
        Employee.fromJson(_employeeJson(status: 'on_site')),
        Employee.fromJson(_employeeJson(status: 'in_transit')),
        Employee.fromJson(_employeeJson(status: 'offline')),
        Employee.fromJson(_employeeJson(status: 'offline')),
      ];
      final c = StatusCounts.of(list);
      expect([c.total, c.onSite, c.inTransit, c.offline], [4, 1, 1, 2]);
    });

    test('request open state', () {
      LocationRequest req(String status, bool awaiting) => LocationRequest.fromJson({
            'id': 1,
            'employee_id': 7,
            'employee_name': 'Ravi Kumar',
            'status': status,
            'reason': null,
            'auto_approved': awaiting,
            'created_at': '2026-11-03T04:52:00+00:00',
            'responded_at': null,
            'fulfilled_at': null,
            'expires_at': '2026-11-03T04:54:00+00:00',
            'location': null,
            'awaiting_fresh_fix': awaiting,
          });
      expect(req('pending', false).isOpen, isTrue);
      expect(req('approved', true).isOpen, isTrue);
      expect(req('approved', false).isOpen, isFalse);
      expect(req('declined', false).status, RequestStatus.declined);
    });
  });

  group('Formatting', () {
    final now = DateTime(2026, 11, 3, 10, 24);
    test('time ago', () {
      expect(timeAgo(null), 'Never');
      expect(timeAgo(now.subtract(const Duration(seconds: 10)), now: now), 'Just now');
      expect(timeAgo(now.subtract(const Duration(minutes: 2)), now: now), '2 minutes ago');
      expect(timeAgo(now.subtract(const Duration(hours: 1)), now: now), '1 hour ago');
    });

    test('coordinates and accuracy match the reference design', () {
      expect(latitude(17.7410), '17.7410° N');
      expect(longitude(83.3370), '83.3370° E');
      expect(latitude(-33.8), '33.8000° S');
      expect(accuracy(12.4), '± 12 metres');
      expect(accuracy(2500), '± 2.5 km');
    });

    test('greeting by hour', () {
      expect(greeting(DateTime(2026, 1, 1, 9)), 'Good Morning!');
      expect(greeting(DateTime(2026, 1, 1, 14)), 'Good Afternoon!');
      expect(greeting(DateTime(2026, 1, 1, 20)), 'Good Evening!');
    });
  });
}
