import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/admin_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'employee_detail_screen.dart';
import 'manage/sites_screen.dart';

/// Who is at each site right now, based on live geofence matches.
class SiteCheckScreen extends StatelessWidget {
  const SiteCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final api = context.read<ApiClient>();
    final t = Theme.of(context).textTheme;
    final sites = store.sites.where((s) => s.active).toList();
    final onSite = store.employees.where((e) => e.status == EmployeeStatus.onSite).toList();

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              BackHeader(
                title: 'Site Check',
                trailing: IconButton(
                  tooltip: 'Manage sites',
                  icon: const Icon(Icons.edit_location_alt_outlined),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SitesScreen())),
                ),
              ),
              Expanded(
                child: sites.isEmpty
                    ? const EmptyState(
                        icon: Icons.apartment_rounded,
                        title: 'No active sites',
                        message: 'Add your client sites with a geofence to see who is where.',
                      )
                    : RefreshIndicator(
                        color: AppColors.orange,
                        onRefresh: store.refresh,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: sites.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                          itemBuilder: (_, i) {
                            final site = sites[i];
                            final here = onSite.where((e) => e.lastLocation?.siteId == site.id).toList();
                            return GlassCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const IconDisc(icon: Icons.apartment_rounded),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(site.name, style: t.titleSmall),
                                            if (site.address != null) Text(site.address!, style: t.bodySmall),
                                          ],
                                        ),
                                      ),
                                      StatusPill(
                                        label: '${here.length} on site',
                                        color: here.isEmpty ? AppColors.muted : AppColors.onSite,
                                        solid: false,
                                      ),
                                    ],
                                  ),
                                  if (here.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    for (final e in here)
                                      InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: () => Navigator.of(context).push(
                                          MaterialPageRoute(builder: (_) => EmployeeDetailScreen(employeeId: e.id)),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 6),
                                          child: Row(
                                            children: [
                                              EmployeeAvatar(employee: e, api: api, size: 34),
                                              const SizedBox(width: 10),
                                              Expanded(child: Text(e.name, style: t.bodyMedium)),
                                              Text(timeAgo(e.lastLocation?.recordedAt), style: t.bodySmall),
                                            ],
                                          ),
                                        ),
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
}
