import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/realtime.dart';
import '../../state/admin_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';
import 'site_check_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final counts = store.counts;
    final shell = AdminShell.of(context);
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();

    return AppBackground(
      skyline: true,
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AppColors.orange,
          onRefresh: store.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              Row(
                children: [
                  const SlgLogo(height: 54),
                  const Spacer(),
                  _RequestsBell(count: store.pendingRequests),
                ],
              ),
              const SizedBox(height: 22),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      '${greeting(now)} 👋',
                      style: t.headlineMedium?.copyWith(fontSize: 24),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: AppColors.orangeTint, borderRadius: BorderRadius.circular(10)),
                    child: Text(headerDate(now),
                        style: const TextStyle(color: AppColors.orangeDeep, fontWeight: FontWeight.w600, fontSize: 12.5)),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text('Field Operations Overview', style: t.bodyMedium),
                  const Spacer(),
                  _ConnectionDot(store: store),
                ],
              ),
              if (store.error != null) ...[
                const SizedBox(height: 14),
                ErrorBanner(message: store.error!, onRetry: store.refresh),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  _StatTile(value: counts.total, label: 'Employees', icon: Icons.groups_rounded, color: AppColors.orange, loading: store.loading,
                      onTap: () => shell.select(2)),
                  _StatTile(value: counts.onSite, label: 'On Site', icon: Icons.location_on_rounded, color: AppColors.onSite, loading: store.loading,
                      onTap: () => shell.openMap(status: EmployeeStatus.onSite)),
                  _StatTile(value: counts.inTransit, label: 'In Transit', icon: Icons.swap_horiz_rounded, color: AppColors.inTransit, loading: store.loading,
                      onTap: () => shell.openMap(status: EmployeeStatus.inTransit)),
                  _StatTile(value: counts.offline, label: 'Offline', icon: Icons.location_off_rounded, color: AppColors.offline, loading: store.loading,
                      onTap: () => shell.openMap(status: EmployeeStatus.offline)),
                ],
              ),
              const SizedBox(height: 22),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 2.5,
                children: [
                  _QuickAction(icon: Icons.map_rounded, label: 'Live Map', onTap: () => shell.select(1)),
                  _QuickAction(icon: Icons.groups_rounded, label: 'Employees', onTap: () => shell.select(2)),
                  _QuickAction(
                    icon: Icons.apartment_rounded,
                    label: 'Site Check',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SiteCheckScreen())),
                  ),
                  _QuickAction(icon: Icons.bar_chart_rounded, label: 'Reports', onTap: () => shell.select(3)),
                ],
              ),
              const SizedBox(height: 26),
              const SectionTitle('Team status'),
              if (!store.loading && store.employees.isEmpty)
                GlassCard(
                  child: EmptyState(
                    icon: Icons.person_add_alt_1_rounded,
                    title: 'No employees yet',
                    message: 'Add employees under More → Manage Employees, then pair their phones.',
                  ),
                )
              else
                ..._teamRows(store).map((row) => Padding(padding: const EdgeInsets.only(bottom: 10), child: row)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _teamRows(AdminStore store) {
    final groups = <int?, List<Employee>>{};
    for (final e in store.employees) {
      groups.putIfAbsent(e.teamId, () => []).add(e);
    }
    final rows = <Widget>[];
    for (final team in store.teams) {
      final members = groups[team.id] ?? [];
      if (members.isEmpty) continue;
      rows.add(_TeamRow(name: team.name, color: AppColors.hex(team.color), counts: StatusCounts.of(members)));
    }
    final unassigned = groups[null] ?? [];
    if (unassigned.isNotEmpty) {
      rows.add(_TeamRow(name: 'Unassigned', color: AppColors.muted, counts: StatusCounts.of(unassigned)));
    }
    return rows;
  }
}

class _RequestsBell extends StatelessWidget {
  const _RequestsBell({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: count == 0 ? 'No pending location requests' : '$count pending location requests',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.notifications_none_rounded, size: 30, color: AppColors.ink),
          ),
          if (count > 0)
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                decoration: const BoxDecoration(color: AppColors.orange, shape: BoxShape.circle),
                child: Text('$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.store});
  final AdminStore store;

  @override
  Widget build(BuildContext context) {
    final live = store.socket == SocketState.connected && store.online;
    final label = !store.online
        ? 'Offline'
        : live
            ? 'Live'
            : 'Reconnecting…';
    final color = !store.online ? AppColors.offline : (live ? AppColors.onSite : AppColors.inTransit);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    required this.loading,
    required this.onTap,
  });

  final int value;
  final String label;
  final IconData icon;
  final Color color;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GlassCard(
          radius: AppRadius.tile,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          onTap: onTap,
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: a, child: c)),
                child: Text(
                  loading ? '–' : '$value',
                  key: ValueKey(loading ? -1 : value),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
                ),
              ),
              const SizedBox(height: 2),
              FittedBox(child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.inkSoft))),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: AppRadius.tile,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: AppColors.orange, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: AppColors.ink))),
        ],
      ),
    );
  }
}

class _TeamRow extends StatelessWidget {
  const _TeamRow({required this.name, required this.color, required this.counts});

  final String name;
  final Color color;
  final StatusCounts counts;

  @override
  Widget build(BuildContext context) {
    final total = counts.total == 0 ? 1 : counts.total;
    return GlassCard(
      radius: AppRadius.tile,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(child: Text(name, style: Theme.of(context).textTheme.titleSmall)),
              Text('${counts.total} staff', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  if (counts.onSite > 0) Expanded(flex: counts.onSite * 100 ~/ total + 1, child: Container(color: AppColors.onSite)),
                  if (counts.inTransit > 0)
                    Expanded(flex: counts.inTransit * 100 ~/ total + 1, child: Container(color: AppColors.inTransit)),
                  if (counts.offline > 0) Expanded(flex: counts.offline * 100 ~/ total + 1, child: Container(color: const Color(0xFFFCA5A5))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _legend(AppColors.onSite, '${counts.onSite} on site'),
              _legend(AppColors.inTransit, '${counts.inTransit} in transit'),
              _legend(AppColors.offline, '${counts.offline} offline'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(Color c, String text) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(text, style: const TextStyle(fontSize: 12, color: AppColors.inkSoft)),
          ],
        ),
      );
}
