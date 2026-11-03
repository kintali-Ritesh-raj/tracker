import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';
import '../../../core/models.dart';
import '../../../state/admin_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Consent and phone-health overview. Admins can see but never change an
/// employee's consent; only the employee's own phone can.
class PermissionsOverviewScreen extends StatefulWidget {
  const PermissionsOverviewScreen({super.key});

  @override
  State<PermissionsOverviewScreen> createState() => _PermissionsOverviewScreenState();
}

class _PermissionsOverviewScreenState extends State<PermissionsOverviewScreen> {
  final Map<int, EmployeeDetail> _details = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    final employees = context.read<AdminStore>().employees;
    final results = await Future.wait(employees.map((e) => api.get('/employees/${e.id}').then<Object?>((v) => v).catchError((_) => null)));
    if (!mounted) return;
    setState(() {
      for (final json in results.whereType<Map<String, dynamic>>()) {
        final d = EmployeeDetail.fromJson(json);
        _details[d.employee.id] = d;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final api = context.read<ApiClient>();
    final details = _details.values.toList()..sort((a, b) => a.employee.name.compareTo(b.employee.name));
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'Location Permissions'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: GlassCard(
                  child: Text(
                    'Employees turn sharing on or off in their own app. Background tracking needs “Allow all the time” '
                    'location, notifications, and no battery restriction on the phone.',
                    style: t.bodyMedium,
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: AppColors.orange))
                    : RefreshIndicator(
                        color: AppColors.orange,
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: details.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final d = details[i];
                            final h = d.activeDevice?.permissionState ?? const {};
                            bool ok(String k) => h[k] == true;
                            return GlassCard(
                              radius: AppRadius.tile,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      EmployeeAvatar(employee: d.employee, api: api, size: 40),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(d.employee.name, style: t.titleSmall),
                                            Text(
                                              d.activeDevice == null
                                                  ? 'No paired phone'
                                                  : 'Phone seen ${timeAgo(d.activeDevice!.lastSeenAt).toLowerCase()}',
                                              style: t.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      StatusPill(
                                        label: d.permission?.sharingEnabled == true ? 'Sharing' : 'Off',
                                        color: d.permission?.sharingEnabled == true ? AppColors.onSite : AppColors.muted,
                                        solid: false,
                                      ),
                                    ],
                                  ),
                                  if (d.activeDevice != null && h.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        _flag('GPS on', ok('services_enabled')),
                                        _flag('Always allow', ok('background')),
                                        _flag('Precise', ok('precise')),
                                        _flag('Notifications', ok('notifications')),
                                        _flag('No battery limit', ok('battery_unrestricted')),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _flag(String label, bool ok) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: ok ? AppColors.onSiteSoft : AppColors.inTransitSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ok ? Icons.check_rounded : Icons.priority_high_rounded, size: 14, color: ok ? AppColors.onSite : const Color(0xFFB45309)),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: ok ? const Color(0xFF166534) : const Color(0xFF92400E))),
          ],
        ),
      );
}
