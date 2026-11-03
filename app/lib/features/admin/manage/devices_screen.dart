import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';
import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../state/admin_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'pairing_code_sheet.dart';

/// Every paired phone. Revoking one cuts its access immediately.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<DeviceInfo> _devices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<ApiClient>().get('/devices') as List;
      setState(() {
        _devices = json.map((d) => DeviceInfo.fromJson(d as Map<String, dynamic>)).where((d) => d.active).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(DeviceInfo d, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Revoke this phone?'),
        content: Text('$name will lose access immediately and must be paired again with a new code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.offline),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<ApiClient>().delete('/devices/${d.id}');
      await _load();
      if (mounted) context.read<AdminStore>().refresh(quiet: true);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final me = context.read<Session>().deviceId;
    final t = Theme.of(context).textTheme;
    final admins = _devices.where((d) => d.role == 'admin').toList();
    final phones = _devices.where((d) => d.role == 'employee').toList();

    Widget row(DeviceInfo d) {
      final owner = d.employeeId == null ? null : store.byId(d.employeeId!);
      final name = d.role == 'admin' ? (d.label ?? 'Admin phone') : (owner?.name ?? 'Employee phone');
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GlassCard(
          radius: AppRadius.tile,
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(
            children: [
              IconDisc(icon: d.role == 'admin' ? Icons.admin_panel_settings_outlined : Icons.smartphone_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.id == me ? '$name (this phone)' : name, style: t.titleSmall),
                    Text(
                      [
                        'Seen ${timeAgo(d.lastSeenAt).toLowerCase()}',
                        if (d.appVersion != null) 'v${d.appVersion}',
                        if (d.batteryLevel != null) '${d.batteryLevel}% battery',
                      ].join(' · '),
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
              if (d.id != me)
                IconButton(
                  tooltip: 'Revoke',
                  icon: const Icon(Icons.link_off_rounded, color: AppColors.offline),
                  onPressed: () => _revoke(d, name),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_moderator_outlined),
        label: const Text('Pair admin phone'),
        onPressed: () async {
          await showPairingCodeSheet(context, null);
          _load();
        },
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'Paired Devices'),
              if (_error != null) Padding(padding: const EdgeInsets.all(16), child: ErrorBanner(message: _error!, onRetry: _load)),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: AppColors.orange))
                    : RefreshIndicator(
                        color: AppColors.orange,
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                          children: [
                            const SectionTitle('Admin phones'),
                            ...admins.map(row),
                            const SectionTitle('Employee phones'),
                            if (phones.isEmpty) Text('No employee phones paired yet.', style: t.bodyMedium),
                            ...phones.map(row),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
