import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/admin_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';
import 'employee_detail_screen.dart';
import 'manage/employee_form_screen.dart';

class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  String _q = '';
  EmployeeStatus? _status;
  int? _teamId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final api = context.read<ApiClient>();
    final list = store.employees
        .where((e) => _status == null || e.status == _status)
        .where((e) => _teamId == null || e.teamId == _teamId)
        .where((e) => _q.isEmpty || e.name.toLowerCase().contains(_q) || e.code.toLowerCase().contains(_q))
        .toList();

    return AppBackground(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            BackHeader(
              title: 'Employees',
              onBack: () => AdminShell.of(context).select(0),
              trailing: IconButton.filled(
                tooltip: 'Add employee',
                style: IconButton.styleFrom(backgroundColor: AppColors.orange),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmployeeFormScreen())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                decoration: const InputDecoration(hintText: 'Search name or employee ID', prefixIcon: Icon(Icons.search_rounded)),
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
            ),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _chip('All', _status == null, () => setState(() => _status = null)),
                  for (final s in EmployeeStatus.values) _chip(s.label, _status == s, () => setState(() => _status = s)),
                  for (final t in store.teams)
                    _chip(t.name, _teamId == t.id, () => setState(() => _teamId = _teamId == t.id ? null : t.id), outline: true),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.orange,
                onRefresh: store.refresh,
                child: list.isEmpty
                    ? ListView(children: [
                        EmptyState(
                          icon: Icons.groups_outlined,
                          title: store.employees.isEmpty ? 'No employees yet' : 'No matches',
                          message: store.employees.isEmpty
                              ? 'Add your field staff, then pair each person\'s phone with a one-time code.'
                              : 'Try a different search or filter.',
                        ),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _EmployeeRow(employee: list[i], api: api),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap, {bool outline = false}) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: active,
          onSelected: (_) => onTap(),
          showCheckmark: false,
          selectedColor: outline ? AppColors.orangeSoft : AppColors.orange,
          backgroundColor: Colors.white,
          side: BorderSide(color: active ? Colors.transparent : AppColors.hairline),
          labelStyle: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: active && !outline ? Colors.white : AppColors.ink,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
}

class _EmployeeRow extends StatelessWidget {
  const _EmployeeRow({required this.employee, required this.api});

  final Employee employee;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final loc = employee.lastLocation;
    final subtitle = [
      employee.roleTitle ?? employee.code,
      if (employee.teamName != null) employee.teamName!,
    ].join(' · ');
    final where = !employee.devicePaired
        ? 'Phone not paired'
        : loc == null
            ? (employee.sharingEnabled ? 'Waiting for first GPS fix' : 'Sharing paused')
            : '${loc.siteName ?? (employee.status == EmployeeStatus.inTransit ? 'In transit' : 'Last seen')} · ${timeAgo(loc.recordedAt)}';
    return GlassCard(
      radius: AppRadius.tile,
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeDetailScreen(employeeId: employee.id))),
      child: Row(
        children: [
          Hero(
            tag: 'avatar-${employee.id}',
            child: EmployeeAvatar(employee: employee, api: api, size: 52, ring: AppColors.status(employee.status)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(employee.name, style: t.titleSmall, overflow: TextOverflow.ellipsis),
                Text(subtitle, style: t.bodySmall, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(where, style: t.bodySmall?.copyWith(color: AppColors.inkSoft), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusPill.employee(employee.status, dense: true),
        ],
      ),
    );
  }
}
