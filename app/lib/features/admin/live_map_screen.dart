import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/realtime.dart';
import '../../state/admin_store.dart';
import '../../ui/marker_factory.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';
import 'employee_detail_screen.dart';
import 'request_location_screen.dart';

class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => LiveMapScreenState();
}

class LiveMapScreenState extends State<LiveMapScreen> {
  // Camera-only fallback when there are no employees or sites yet.
  static const _fallbackCamera = CameraPosition(target: LatLng(17.6868, 83.2185), zoom: 11.5);

  GoogleMapController? _map;
  late final MarkerFactory _markers;
  late final AdminStore _store;
  EmployeeStatus? _status;
  int? _teamId;
  int? _selectedId;
  MapType _mapType = MapType.normal;
  Set<Marker> _markerSet = {};
  bool _fittedOnce = false;
  int _buildGeneration = 0;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _store = context.read<AdminStore>();
    _markers = MarkerFactory(context.read<ApiClient>());
    _store.addListener(_onStore);
    // Re-render "updated N min ago" labels.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildMarkers());
  }

  @override
  void dispose() {
    _store.removeListener(_onStore);
    _clock?.cancel();
    _map?.dispose();
    super.dispose();
  }

  void apply({EmployeeStatus? status, int? focusEmployeeId}) {
    setState(() {
      _status = status;
      if (focusEmployeeId != null) {
        _status = null;
        _teamId = null;
        _selectedId = focusEmployeeId;
      }
    });
    _rebuildMarkers();
    final e = focusEmployeeId == null ? null : _store.byId(focusEmployeeId);
    if (e?.lastLocation != null) {
      _map?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(e!.lastLocation!.latitude, e.lastLocation!.longitude), 16));
    } else if (focusEmployeeId == null) {
      _fitAll();
    }
  }

  void _onStore() => _rebuildMarkers();

  List<Employee> get _visible => _store.mapEmployees
      .where((e) => _status == null || e.status == _status)
      .where((e) => _teamId == null || e.teamId == _teamId)
      .toList();

  Future<void> _rebuildMarkers() async {
    if (!mounted) return;
    final generation = ++_buildGeneration;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final visible = _visible;
    final markers = <Marker>{};
    for (final e in visible) {
      final loc = e.lastLocation!;
      markers.add(Marker(
        markerId: MarkerId('e${e.id}'),
        position: LatLng(loc.latitude, loc.longitude),
        icon: await _markers.forEmployee(e, dpr),
        anchor: const Offset(0.5, 1),
        zIndexInt: e.id == _selectedId ? 10 : (e.status == EmployeeStatus.offline ? 0 : 1),
        infoWindow: InfoWindow(title: e.name, snippet: '${e.status.label} · ${timeAgo(loc.recordedAt)}'),
        onTap: () => _select(e.id),
      ));
    }
    if (!mounted || generation != _buildGeneration) return;
    setState(() => _markerSet = markers);
    if (!_fittedOnce && markers.isNotEmpty && _map != null) {
      _fittedOnce = true;
      _fitAll();
    }
  }

  void _select(int? id) {
    HapticFeedback.selectionClick();
    setState(() => _selectedId = id);
    _rebuildMarkers();
  }

  Set<Circle> _circles() {
    final circles = <Circle>{
      for (final s in _store.sites.where((s) => s.active))
        Circle(
          circleId: CircleId('s${s.id}'),
          center: LatLng(s.latitude, s.longitude),
          radius: s.radiusM.toDouble(),
          fillColor: AppColors.orange.withValues(alpha: 0.08),
          strokeColor: AppColors.orange.withValues(alpha: 0.45),
          strokeWidth: 1,
        ),
    };
    final selected = _selectedId == null ? null : _store.byId(_selectedId!);
    final loc = selected?.lastLocation;
    if (loc != null) {
      circles.add(Circle(
        circleId: const CircleId('accuracy'),
        center: LatLng(loc.latitude, loc.longitude),
        radius: loc.accuracyM,
        fillColor: const Color(0x223B82F6),
        strokeColor: const Color(0x663B82F6),
        strokeWidth: 1,
      ));
    }
    return circles;
  }

  Future<void> _fitAll() async {
    final points = [
      for (final m in _markerSet) m.position,
      if (_markerSet.isEmpty) for (final s in _store.sites) LatLng(s.latitude, s.longitude),
    ];
    if (_map == null || points.isEmpty) return;
    if (points.length == 1) {
      await _map!.animateCamera(CameraUpdate.newLatLngZoom(points.first, 15));
      return;
    }
    var south = points.first.latitude, north = south, west = points.first.longitude, east = west;
    for (final p in points) {
      if (p.latitude < south) south = p.latitude;
      if (p.latitude > north) north = p.latitude;
      if (p.longitude < west) west = p.longitude;
      if (p.longitude > east) east = p.longitude;
    }
    await _map!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(south, west), northeast: LatLng(north, east)),
      72,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final all = store.mapEmployees.where((e) => _teamId == null || e.teamId == _teamId).toList();
    final counts = StatusCounts.of(all);
    final selected = _selectedId == null ? null : store.byId(_selectedId!);
    final live = store.socket == SocketState.connected && store.online;

    return Scaffold(
      backgroundColor: AppColors.cream,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            BackHeader(
              title: 'Live Tracking',
              onBack: () => AdminShell.of(context).select(0),
              trailing: StatusPill(label: live ? 'Live' : (store.online ? 'Connecting' : 'Offline'),
                  color: live ? AppColors.onSite : (store.online ? AppColors.inTransit : AppColors.offline)),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _FilterChip(label: 'All (${counts.total})', active: _status == null, onTap: () => apply(status: null)),
                  _FilterChip(label: 'On Site (${counts.onSite})', active: _status == EmployeeStatus.onSite, onTap: () => apply(status: EmployeeStatus.onSite)),
                  _FilterChip(label: 'In Transit (${counts.inTransit})', active: _status == EmployeeStatus.inTransit, onTap: () => apply(status: EmployeeStatus.inTransit)),
                  _FilterChip(label: 'Offline (${counts.offline})', active: _status == EmployeeStatus.offline, onTap: () => apply(status: EmployeeStatus.offline)),
                  if (store.teams.isNotEmpty) _TeamFilter(teams: store.teams, value: _teamId, onChanged: (id) {
                    setState(() => _teamId = id);
                    _rebuildMarkers();
                  }),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Stack(
                    children: [
                      GoogleMap(
                        initialCameraPosition: _fallbackCamera,
                        mapType: _mapType,
                        markers: _markerSet,
                        circles: _circles(),
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                        mapToolbarEnabled: false,
                        compassEnabled: true,
                        padding: EdgeInsets.only(bottom: selected != null ? 190 : 90),
                        onMapCreated: (c) {
                          _map = c;
                          if (_markerSet.isNotEmpty) {
                            _fittedOnce = true;
                            _fitAll();
                          } else if (store.sites.isNotEmpty) {
                            _fitAll();
                          }
                        },
                        onTap: (_) => _select(null),
                      ),
                      Positioned(
                        left: 12,
                        top: 12,
                        child: GlassCard(
                          blur: true,
                          radius: 12,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Text(
                            store.lastSync == null ? 'Waiting for data…' : 'Updated ${timeAgo(store.lastSync).toLowerCase()}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.inkSoft),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: Column(
                          children: [
                            _MapButton(
                              icon: Icons.layers_outlined,
                              tooltip: 'Map style',
                              onTap: () => setState(() => _mapType = switch (_mapType) {
                                    MapType.normal => MapType.hybrid,
                                    MapType.hybrid => MapType.terrain,
                                    _ => MapType.normal,
                                  }),
                            ),
                            const SizedBox(height: 10),
                            _MapButton(icon: Icons.near_me_outlined, tooltip: 'Recenter', onTap: _fitAll),
                          ],
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: selected != null ? 200 : 100,
                        child: GlassCard(
                          blur: true,
                          radius: 16,
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              IconButton(tooltip: 'Zoom in', icon: const Icon(Icons.add), onPressed: () => _map?.animateCamera(CameraUpdate.zoomIn())),
                              Container(width: 24, height: 1, color: AppColors.hairline),
                              IconButton(tooltip: 'Zoom out', icon: const Icon(Icons.remove), onPressed: () => _map?.animateCamera(CameraUpdate.zoomOut())),
                            ],
                          ),
                        ),
                      ),
                      if (!store.loading && _markerSet.isEmpty)
                        Positioned(
                          left: 24,
                          right: 24,
                          top: 80,
                          child: GlassCard(
                            blur: true,
                            child: Text(
                              store.mapEmployees.isEmpty
                                  ? 'No live locations yet. Employees appear here once they turn on location sharing in their app.'
                                  : 'No employees match this filter.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ),
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        left: 12,
                        right: 12,
                        bottom: selected != null ? 96 : -220,
                        child: selected == null ? const SizedBox.shrink() : _SelectedCard(employee: selected),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.orange : Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: active ? AppShadow.button : AppShadow.soft,
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: active ? Colors.white : AppColors.ink)),
        ),
      ),
    );
  }
}

class _TeamFilter extends StatelessWidget {
  const _TeamFilter({required this.teams, required this.value, required this.onChanged});

  final List<Team> teams;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = teams.where((t) => t.id == value).firstOrNull;
    return PopupMenuButton<int?>(
      tooltip: 'Filter by team',
      onSelected: (v) => onChanged(v == -1 ? null : v),
      itemBuilder: (_) => [
        const PopupMenuItem(value: -1, child: Text('All teams')),
        for (final t in teams) PopupMenuItem(value: t.id, child: Text(t.name)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: current != null ? AppColors.orangeSoft : Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadow.soft,
        ),
        child: Row(
          children: [
            const Icon(Icons.groups_outlined, size: 18, color: AppColors.orangeDeep),
            const SizedBox(width: 6),
            Text(current?.name ?? 'Team', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GlassCard(
        blur: true,
        radius: 24,
        padding: const EdgeInsets.all(12),
        onTap: onTap,
        child: Icon(icon, size: 24, color: AppColors.ink),
      ),
    );
  }
}

class _SelectedCard extends StatelessWidget {
  const _SelectedCard({required this.employee});
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final loc = employee.lastLocation!;
    final t = Theme.of(context).textTheme;
    return GlassCard(
      blur: true,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              EmployeeAvatar(employee: employee, api: api, size: 52, ring: AppColors.status(employee.status)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(employee.name, style: t.titleMedium, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      loc.siteName ?? loc.address ?? '${latitude(loc.latitude)}, ${longitude(loc.longitude)}',
                      style: t.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${timeAgo(loc.recordedAt)} · ${accuracy(loc.accuracyM)}${loc.lowAccuracy ? ' · weak GPS' : ''}',
                      style: t.bodySmall?.copyWith(color: loc.lowAccuracy ? AppColors.inTransit : null),
                    ),
                  ],
                ),
              ),
              StatusPill.employee(employee.status, dense: true),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.orangeDeep,
                    side: const BorderSide(color: AppColors.orangeSoft),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  icon: const Icon(Icons.person_outline_rounded),
                  label: const Text('Details'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => EmployeeDetailScreen(employeeId: employee.id)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.orange,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  icon: const Icon(Icons.near_me_rounded),
                  label: const Text('Request'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => RequestLocationScreen(employeeId: employee.id)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
