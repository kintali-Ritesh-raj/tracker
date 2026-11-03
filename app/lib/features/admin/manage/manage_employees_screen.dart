import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/models.dart';
import '../../../state/admin_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import '../employee_detail_screen.dart';
import 'employee_form_screen.dart';
import 'pairing_code_sheet.dart';

/// Admin list including deactivated staff, with pairing and reactivation.
class ManageEmployeesScreen extends StatefulWidget {
  const ManageEmployeesScreen({super.key});

  @override
  State<ManageEmployeesScreen> createState() => _ManageEmployeesScreenState();
}

class _ManageEmployeesScreenState extends State<ManageEmployeesScreen> {
  List<Employee> _all = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<ApiClient>().get('/employees', query: {'include_inactive': 'true'}) as List;
      setState(() {
        _all = json.map((j) => Employee.fromJson(j as Map<String, dynamic>)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reactivate(Employee e) async {
    try {
      final json = await context.read<ApiClient>().patch('/employees/${e.id}', {'active': true});
      if (!mounted) return;
      context.read<AdminStore>().upsert(Employee.fromJson(json as Map<String, dynamic>));
      await _load();
      if (mounted) showMessage(context, '${e.name} reactivated. Pair their phone again to resume tracking.');
    } on ApiException catch (err) {
      if (mounted) showMessage(context, err.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final active = _all.where((e) => e.active).toList();
    final inactive = _all.where((e) => !e.active).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add employee'),
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmployeeFormScreen()));
          _load();
        },
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'Manage Employees'),
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
                            if (_all.isEmpty)
                              const EmptyState(
                                icon: Icons.groups_outlined,
                                title: 'No employees yet',
                                message: 'Tap “Add employee” to create the first one.',
                              ),
                            for (final e in active) _row(e, api),
                            if (inactive.isNotEmpty) ...[
                              const SectionTitle('Deactivated'),
                              for (final e in inactive) _row(e, api, inactive: true),
                            ],
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

  Widget _row(Employee e, ApiClient api, {bool inactive = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: inactive ? 0.6 : 1,
        child: GlassCard(
          radius: AppRadius.tile,
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          onTap: inactive
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeDetailScreen(employeeId: e.id)));
                  _load();
                },
          child: Row(
            children: [
              EmployeeAvatar(employee: e, api: api, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.name, style: Theme.of(context).textTheme.titleSmall),
                    Text('${e.code}${e.teamName == null ? '' : ' · ${e.teamName}'} · ${e.devicePaired ? 'Phone paired' : 'Not paired'}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (inactive)
                TextButton(onPressed: () => _reactivate(e), child: const Text('Reactivate'))
              else
                IconButton(
                  tooltip: 'Pair phone',
                  icon: Icon(e.devicePaired ? Icons.phonelink_ring_rounded : Icons.qr_code_rounded, color: AppColors.orange),
                  onPressed: () async {
                    await showPairingCodeSheet(context, e);
                    _load();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
