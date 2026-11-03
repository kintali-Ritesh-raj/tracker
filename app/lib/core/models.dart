// Data classes mirroring backend/app/schemas.py.

DateTime? _date(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();
double? _double(dynamic v) => v == null ? null : (v as num).toDouble();

enum EmployeeStatus {
  onSite('on_site', 'On Site'),
  inTransit('in_transit', 'In Transit'),
  offline('offline', 'Offline');

  const EmployeeStatus(this.wire, this.label);
  final String wire;
  final String label;

  static EmployeeStatus parse(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => EmployeeStatus.offline);
}

enum RequestStatus {
  pending('Pending'),
  approved('Approved'),
  declined('Declined'),
  unavailable('Unavailable');

  const RequestStatus(this.label);
  final String label;

  static RequestStatus parse(String? value) =>
      values.firstWhere((s) => s.name == value, orElse: () => RequestStatus.unavailable);
}

class LocationFix {
  LocationFix({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.recordedAt,
    required this.source,
    this.speedMps,
    this.heading,
    this.altitudeM,
    this.siteId,
    this.siteName,
    this.address,
    this.lowAccuracy = false,
  });

  final int id;
  final double latitude;
  final double longitude;
  final double accuracyM;
  final double? altitudeM;
  final double? speedMps;
  final double? heading;
  final DateTime recordedAt;
  final String source;
  final int? siteId;
  final String? siteName;
  final String? address;
  final bool lowAccuracy;

  factory LocationFix.fromJson(Map<String, dynamic> j) => LocationFix(
        id: j['id'] as int,
        latitude: _double(j['latitude'])!,
        longitude: _double(j['longitude'])!,
        accuracyM: _double(j['accuracy_m'])!,
        altitudeM: _double(j['altitude_m']),
        speedMps: _double(j['speed_mps']),
        heading: _double(j['heading']),
        recordedAt: _date(j['recorded_at'])!,
        source: j['source'] as String? ?? 'stream',
        siteId: j['site_id'] as int?,
        siteName: j['site_name'] as String?,
        address: j['address'] as String?,
        lowAccuracy: j['low_accuracy'] as bool? ?? false,
      );
}

class Employee {
  Employee({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.sharingEnabled,
    required this.devicePaired,
    required this.hasPhoto,
    required this.photoVersion,
    required this.active,
    this.phone,
    this.roleTitle,
    this.teamId,
    this.teamName,
    this.teamColor,
    this.lastLocation,
  });

  final int id;
  final String code;
  final String name;
  final String? phone;
  final String? roleTitle;
  final int? teamId;
  final String? teamName;
  final String? teamColor;
  final bool hasPhoto;
  final int photoVersion;
  final bool active;
  final EmployeeStatus status;
  final bool sharingEnabled;
  final bool devicePaired;
  final LocationFix? lastLocation;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  factory Employee.fromJson(Map<String, dynamic> j) => Employee(
        id: j['id'] as int,
        code: j['employee_code'] as String,
        name: j['full_name'] as String,
        phone: j['phone'] as String?,
        roleTitle: j['role_title'] as String?,
        teamId: j['team_id'] as int?,
        teamName: j['team_name'] as String?,
        teamColor: j['team_color'] as String?,
        hasPhoto: j['has_photo'] as bool? ?? false,
        photoVersion: j['photo_version'] as int? ?? 0,
        active: j['active'] as bool? ?? true,
        status: EmployeeStatus.parse(j['status'] as String?),
        sharingEnabled: j['sharing_enabled'] as bool? ?? false,
        devicePaired: j['device_paired'] as bool? ?? false,
        lastLocation: j['last_location'] == null
            ? null
            : LocationFix.fromJson(j['last_location'] as Map<String, dynamic>),
      );
}

class Permission {
  Permission({
    required this.sharingEnabled,
    required this.backgroundEnabled,
    required this.historyEnabled,
    this.consentedAt,
  });

  final bool sharingEnabled;
  final bool backgroundEnabled;
  final bool historyEnabled;
  final DateTime? consentedAt;

  factory Permission.fromJson(Map<String, dynamic> j) => Permission(
        sharingEnabled: j['sharing_enabled'] as bool,
        backgroundEnabled: j['background_enabled'] as bool,
        historyEnabled: j['history_enabled'] as bool,
        consentedAt: _date(j['consented_at']),
      );
}

class DeviceInfo {
  DeviceInfo({
    required this.id,
    required this.role,
    this.employeeId,
    this.label,
    this.platform,
    this.appVersion,
    this.batteryLevel,
    this.permissionState,
    this.hasPush = false,
    this.lastSeenAt,
    this.revokedAt,
    required this.createdAt,
  });

  final int id;
  final String role;
  final int? employeeId;
  final String? label;
  final String? platform;
  final String? appVersion;
  final int? batteryLevel;
  final Map<String, dynamic>? permissionState;
  final bool hasPush;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;
  final DateTime createdAt;

  bool get active => revokedAt == null;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['id'] as int,
        role: j['role'] as String,
        employeeId: j['employee_id'] as int?,
        label: j['label'] as String?,
        platform: j['platform'] as String?,
        appVersion: j['app_version'] as String?,
        batteryLevel: j['battery_level'] as int?,
        permissionState: j['permission_state'] as Map<String, dynamic>?,
        hasPush: j['has_push'] as bool? ?? false,
        lastSeenAt: _date(j['last_seen_at']),
        revokedAt: _date(j['revoked_at']),
        createdAt: _date(j['created_at'])!,
      );
}

class EmployeeDetail {
  EmployeeDetail({required this.employee, this.permission, required this.devices});

  final Employee employee;
  final Permission? permission;
  final List<DeviceInfo> devices;

  DeviceInfo? get activeDevice => devices.where((d) => d.active).firstOrNull;

  factory EmployeeDetail.fromJson(Map<String, dynamic> j) => EmployeeDetail(
        employee: Employee.fromJson(j),
        permission: j['permission'] == null
            ? null
            : Permission.fromJson(j['permission'] as Map<String, dynamic>),
        devices: (j['devices'] as List)
            .map((d) => DeviceInfo.fromJson(d as Map<String, dynamic>))
            .toList(),
      );
}

class LocationRequest {
  LocationRequest({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.status,
    required this.autoApproved,
    required this.createdAt,
    required this.expiresAt,
    required this.awaitingFreshFix,
    this.reason,
    this.respondedAt,
    this.fulfilledAt,
    this.location,
  });

  final int id;
  final int employeeId;
  final String employeeName;
  final RequestStatus status;
  final String? reason;
  final bool autoApproved;
  final DateTime createdAt;
  final DateTime? respondedAt;
  final DateTime? fulfilledAt;
  final DateTime expiresAt;
  final LocationFix? location;
  final bool awaitingFreshFix;

  bool get isOpen =>
      status == RequestStatus.pending || (status == RequestStatus.approved && awaitingFreshFix);

  factory LocationRequest.fromJson(Map<String, dynamic> j) => LocationRequest(
        id: j['id'] as int,
        employeeId: j['employee_id'] as int,
        employeeName: j['employee_name'] as String,
        status: RequestStatus.parse(j['status'] as String?),
        reason: j['reason'] as String?,
        autoApproved: j['auto_approved'] as bool? ?? false,
        createdAt: _date(j['created_at'])!,
        respondedAt: _date(j['responded_at']),
        fulfilledAt: _date(j['fulfilled_at']),
        expiresAt: _date(j['expires_at'])!,
        awaitingFreshFix: j['awaiting_fresh_fix'] as bool? ?? false,
        location: j['location'] == null
            ? null
            : LocationFix.fromJson(j['location'] as Map<String, dynamic>),
      );
}

class Team {
  Team({required this.id, required this.name, required this.color, this.description, this.employeeCount = 0});

  final int id;
  final String name;
  final String? description;
  final String color;
  final int employeeCount;

  factory Team.fromJson(Map<String, dynamic> j) => Team(
        id: j['id'] as int,
        name: j['name'] as String,
        description: j['description'] as String?,
        color: j['color'] as String? ?? '#F97316',
        employeeCount: j['employee_count'] as int? ?? 0,
      );
}

class Site {
  Site({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusM,
    required this.active,
    this.address,
  });

  final int id;
  final String name;
  final String? address;
  final double latitude;
  final double longitude;
  final int radiusM;
  final bool active;

  factory Site.fromJson(Map<String, dynamic> j) => Site(
        id: j['id'] as int,
        name: j['name'] as String,
        address: j['address'] as String?,
        latitude: _double(j['latitude'])!,
        longitude: _double(j['longitude'])!,
        radiusM: j['radius_m'] as int,
        active: j['active'] as bool? ?? true,
      );
}

class StatusCounts {
  StatusCounts({required this.total, required this.onSite, required this.inTransit, required this.offline});

  final int total;
  final int onSite;
  final int inTransit;
  final int offline;

  factory StatusCounts.fromJson(Map<String, dynamic> j) => StatusCounts(
        total: j['total'] as int,
        onSite: j['on_site'] as int,
        inTransit: j['in_transit'] as int,
        offline: j['offline'] as int,
      );

  factory StatusCounts.of(Iterable<Employee> employees) {
    var onSite = 0, inTransit = 0, offline = 0;
    for (final e in employees) {
      switch (e.status) {
        case EmployeeStatus.onSite:
          onSite++;
        case EmployeeStatus.inTransit:
          inTransit++;
        case EmployeeStatus.offline:
          offline++;
      }
    }
    return StatusCounts(total: onSite + inTransit + offline, onSite: onSite, inTransit: inTransit, offline: offline);
  }
}

class AppSettings {
  AppSettings({
    required this.offlineAfterMinutes,
    required this.requestTimeoutSeconds,
    required this.defaultSiteRadiusM,
    required this.trackingIntervalSeconds,
    required this.trackingDistanceFilterM,
    required this.historyRetentionDays,
  });

  final int offlineAfterMinutes;
  final int requestTimeoutSeconds;
  final int defaultSiteRadiusM;
  final int trackingIntervalSeconds;
  final int trackingDistanceFilterM;
  final int historyRetentionDays;

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        offlineAfterMinutes: j['offline_after_minutes'] as int,
        requestTimeoutSeconds: j['request_timeout_seconds'] as int,
        defaultSiteRadiusM: j['default_site_radius_m'] as int,
        trackingIntervalSeconds: j['tracking_interval_seconds'] as int,
        trackingDistanceFilterM: j['tracking_distance_filter_m'] as int,
        historyRetentionDays: j['history_retention_days'] as int,
      );

  Map<String, dynamic> toJson() => {
        'offline_after_minutes': offlineAfterMinutes,
        'request_timeout_seconds': requestTimeoutSeconds,
        'default_site_radius_m': defaultSiteRadiusM,
        'tracking_interval_seconds': trackingIntervalSeconds,
        'tracking_distance_filter_m': trackingDistanceFilterM,
        'history_retention_days': historyRetentionDays,
      };
}
