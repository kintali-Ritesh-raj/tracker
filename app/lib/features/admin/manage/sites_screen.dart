import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/models.dart';
import '../../../services/location_service.dart';
import '../../../state/admin_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class SitesScreen extends StatelessWidget {
  const SitesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('New site'),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SiteFormScreen())),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'Sites / Locations'),
              Expanded(
                child: store.sites.isEmpty
                    ? const EmptyState(
                        icon: Icons.location_city_rounded,
                        title: 'No sites yet',
                        message: 'Add each client location with a geofence. Employees inside a geofence show as On Site.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: store.sites.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final s = store.sites[i];
                          final here = store.employees.where((e) => e.status == EmployeeStatus.onSite && e.lastLocation?.siteId == s.id).length;
                          return GlassCard(
                            radius: AppRadius.tile,
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SiteFormScreen(existing: s))),
                            child: Row(
                              children: [
                                IconDisc(icon: Icons.apartment_rounded, color: s.active ? AppColors.orange : AppColors.muted),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(s.name, style: Theme.of(context).textTheme.titleSmall),
                                      Text(
                                        '${s.address ?? 'No address'} · ${s.radiusM} m${s.active ? '' : ' · inactive'}',
                                        style: Theme.of(context).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                Text('$here on site', style: const TextStyle(color: AppColors.onSite, fontWeight: FontWeight.w600, fontSize: 12.5)),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SiteFormScreen extends StatefulWidget {
  const SiteFormScreen({super.key, this.existing});
  final Site? existing;

  @override
  State<SiteFormScreen> createState() => _SiteFormScreenState();
}

class _SiteFormScreenState extends State<SiteFormScreen> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _address = TextEditingController(text: widget.existing?.address);
  late LatLng? _center = widget.existing == null ? null : LatLng(widget.existing!.latitude, widget.existing!.longitude);
  late double _radius = (widget.existing?.radiusM ?? 150).toDouble();
  late bool _active = widget.existing?.active ?? true;
  GoogleMapController? _map;
  bool _saving = false;
  bool _locating = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    if (!await LocationService.requestForeground()) {
      setState(() => _locating = false);
      if (mounted) showMessage(context, 'Allow location access to use your position.');
      return;
    }
    final fix = await LocationService.currentFix();
    setState(() => _locating = false);
    if (fix == null) {
      if (mounted) showMessage(context, 'Could not get a GPS fix. Tap the map instead.');
      return;
    }
    final p = LatLng(fix.latitude, fix.longitude);
    setState(() => _center = p);
    _map?.animateCamera(CameraUpdate.newLatLngZoom(p, 17));
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _center == null) {
      setState(() => _error = 'Give the site a name and place it on the map.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = {
      'name': _name.text.trim(),
      'address': _address.text.trim().isEmpty ? null : _address.text.trim(),
      'latitude': _center!.latitude,
      'longitude': _center!.longitude,
      'radius_m': _radius.round(),
      'active': _active,
    };
    final api = context.read<ApiClient>();
    final store = context.read<AdminStore>();
    try {
      if (widget.existing == null) {
        await api.post('/sites', body);
      } else {
        await api.patch('/sites/${widget.existing!.id}', body);
      }
      await store.refresh(quiet: true);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final api = context.read<ApiClient>();
    final store = context.read<AdminStore>();
    try {
      await api.delete('/sites/${widget.existing!.id}');
      await store.refresh(quiet: true);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = _center;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              BackHeader(title: widget.existing == null ? 'New Site' : 'Edit Site'),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      child: SizedBox(
                        height: 260,
                        child: Stack(
                          children: [
                            GoogleMap(
                              initialCameraPosition: CameraPosition(target: center ?? const LatLng(17.6868, 83.2185), zoom: center == null ? 12 : 16.5),
                              onMapCreated: (c) => _map = c,
                              onTap: (p) => setState(() => _center = p),
                              myLocationButtonEnabled: false,
                              zoomControlsEnabled: false,
                              markers: {if (center != null) Marker(markerId: const MarkerId('site'), position: center, draggable: true, onDragEnd: (p) => setState(() => _center = p))},
                              circles: {
                                if (center != null)
                                  Circle(
                                    circleId: const CircleId('fence'),
                                    center: center,
                                    radius: _radius,
                                    fillColor: AppColors.orange.withValues(alpha: 0.15),
                                    strokeColor: AppColors.orange,
                                    strokeWidth: 2,
                                  ),
                              },
                            ),
                            Positioned(
                              left: 10,
                              bottom: 10,
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.ink),
                                onPressed: _locating ? null : _useMyLocation,
                                icon: _locating
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.my_location_rounded, size: 18),
                                label: const Text('Use my location'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Text(center == null ? 'Tap the map to place the site.' : 'Tap or drag the pin to adjust.',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    const SizedBox(height: 14),
                    GlassCard(
                      child: Column(
                        children: [
                          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Site name', hintText: 'e.g. MVP Colony Block A')),
                          const SizedBox(height: 12),
                          TextField(controller: _address, decoration: const InputDecoration(labelText: 'Address (optional)')),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Text('Geofence radius'),
                              const Spacer(),
                              Text('${_radius.round()} m', style: const TextStyle(fontWeight: FontWeight.w700)),
                            ],
                          ),
                          Slider(
                            value: _radius,
                            min: 30,
                            max: 1000,
                            divisions: 97,
                            activeColor: AppColors.orange,
                            onChanged: (v) => setState(() => _radius = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Active'),
                            subtitle: const Text('Inactive sites are ignored for On Site status'),
                            value: _active,
                            onChanged: (v) => setState(() => _active = v),
                          ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[const SizedBox(height: 14), ErrorBanner(message: _error!)],
                    const SizedBox(height: 20),
                    PrimaryButton(label: 'Save Site', icon: Icons.check_rounded, busy: _saving, onPressed: _save),
                    if (widget.existing != null)
                      TextButton(onPressed: _delete, child: const Text('Delete site', style: TextStyle(color: AppColors.offline))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
