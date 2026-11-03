import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/models.dart' show AppSettings;
import '../../../services/push_service.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Server-side behaviour shared by every phone: status thresholds, map
/// geofence defaults and the employee tracking cadence.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  AppSettings? _s;
  String? _error;
  bool _saving = false;
  bool _notifications = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    final granted = await Permission.notification.isGranted;
    try {
      final json = await api.get('/settings');
      setState(() {
        _s = AppSettings.fromJson(json as Map<String, dynamic>);
        _notifications = granted;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<ApiClient>().put('/settings', _s!.toJson());
      if (mounted) showMessage(context, 'Settings saved. Employee phones pick them up the next time sharing starts.');
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  AppSettings _copy({int? offline, int? timeout, int? radius, int? interval, int? distance, int? retention}) {
    final s = _s!;
    return AppSettings(
      offlineAfterMinutes: offline ?? s.offlineAfterMinutes,
      requestTimeoutSeconds: timeout ?? s.requestTimeoutSeconds,
      defaultSiteRadiusM: radius ?? s.defaultSiteRadiusM,
      trackingIntervalSeconds: interval ?? s.trackingIntervalSeconds,
      trackingDistanceFilterM: distance ?? s.trackingDistanceFilterM,
      historyRetentionDays: retention ?? s.historyRetentionDays,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'App Settings'),
              Expanded(
                child: s == null
                    ? Center(
                        child: _error == null
                            ? const CircularProgressIndicator(color: AppColors.orange)
                            : Padding(padding: const EdgeInsets.all(16), child: ErrorBanner(message: _error!, onRetry: _load)),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                        children: [
                          const SectionTitle('Map & status'),
                          GlassCard(
                            child: Column(
                              children: [
                                _Stepper(
                                  label: 'Mark offline after',
                                  help: 'No fix for this long → Offline',
                                  value: s.offlineAfterMinutes,
                                  unit: 'min',
                                  min: 5,
                                  max: 120,
                                  step: 5,
                                  onChanged: (v) => setState(() => _s = _copy(offline: v)),
                                ),
                                _Stepper(
                                  label: 'Default geofence',
                                  help: 'Radius suggested for new sites',
                                  value: s.defaultSiteRadiusM,
                                  unit: 'm',
                                  min: 30,
                                  max: 1000,
                                  step: 10,
                                  onChanged: (v) => setState(() => _s = _copy(radius: v)),
                                ),
                              ],
                            ),
                          ),
                          const SectionTitle('Employee tracking'),
                          GlassCard(
                            child: Column(
                              children: [
                                _Stepper(
                                  label: 'Update interval',
                                  help: 'Shorter = fresher map, more battery',
                                  value: s.trackingIntervalSeconds,
                                  unit: 's',
                                  min: 15,
                                  max: 600,
                                  step: 15,
                                  onChanged: (v) => setState(() => _s = _copy(interval: v)),
                                ),
                                _Stepper(
                                  label: 'Minimum movement',
                                  help: 'Skip fixes until the phone moves this far',
                                  value: s.trackingDistanceFilterM,
                                  unit: 'm',
                                  min: 0,
                                  max: 200,
                                  step: 5,
                                  onChanged: (v) => setState(() => _s = _copy(distance: v)),
                                ),
                              ],
                            ),
                          ),
                          const SectionTitle('Location requests'),
                          GlassCard(
                            child: _Stepper(
                              label: 'Wait for response',
                              help: 'Then the request becomes Unavailable',
                              value: s.requestTimeoutSeconds,
                              unit: 's',
                              min: 30,
                              max: 600,
                              step: 30,
                              onChanged: (v) => setState(() => _s = _copy(timeout: v)),
                            ),
                          ),
                          const SectionTitle('Notifications on this phone'),
                          GlassCard(
                            child: Column(
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(_notifications ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                                      color: AppColors.orange),
                                  title: Text(_notifications ? 'Notifications allowed' : 'Notifications blocked'),
                                  trailing: _notifications
                                      ? null
                                      : TextButton(
                                          onPressed: () async {
                                            await Permission.notification.request();
                                            _load();
                                          },
                                          child: const Text('Allow'),
                                        ),
                                ),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.cloud_outlined, color: AppColors.orange),
                                  title: Text(PushService.enabled ? 'Push messaging active' : 'Push messaging not configured'),
                                  subtitle: PushService.enabled
                                      ? null
                                      : const Text('Build the app with google-services.json to reach phones that are closed.'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          PrimaryButton(label: 'Save Settings', icon: Icons.check_rounded, busy: _saving, onPressed: _save),
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

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.help,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  final String label;
  final String help;
  final int value;
  final String unit;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleSmall),
                Text(help, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Decrease',
            onPressed: value - step < min ? null : () => onChanged(value - step),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 64,
            child: Text('$value $unit', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            tooltip: 'Increase',
            onPressed: value + step > max ? null : () => onChanged(value + step),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}
