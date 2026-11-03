import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/models.dart';
import '../../../state/admin_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

const _palette = ['#F97316', '#16A34A', '#2563EB', '#9333EA', '#DB2777', '#0891B2', '#CA8A04', '#57534E'];

class TeamsScreen extends StatelessWidget {
  const TeamsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.orange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New team'),
        onPressed: () => _edit(context, null),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'Manage Teams'),
              Expanded(
                child: store.teams.isEmpty
                    ? const EmptyState(
                        icon: Icons.diversity_3_rounded,
                        title: 'No teams yet',
                        message: 'Group staff by shift, client or area. Assign people to a team from their employee profile.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: store.teams.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final team = store.teams[i];
                          final members = store.employees.where((e) => e.teamId == team.id);
                          final counts = StatusCounts.of(members);
                          return GlassCard(
                            radius: AppRadius.tile,
                            onTap: () => _edit(context, team),
                            child: Row(
                              children: [
                                CircleAvatar(radius: 20, backgroundColor: AppColors.hex(team.color).withValues(alpha: 0.15),
                                    child: Icon(Icons.groups_rounded, color: AppColors.hex(team.color))),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(team.name, style: Theme.of(context).textTheme.titleSmall),
                                      Text('${counts.total} staff · ${counts.onSite} on site · ${counts.inTransit} in transit',
                                          style: Theme.of(context).textTheme.bodySmall),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded),
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

  Future<void> _edit(BuildContext context, Team? team) async {
    final name = TextEditingController(text: team?.name);
    final description = TextEditingController(text: team?.description);
    var color = team?.color ?? _palette.first;
    final api = context.read<ApiClient>();
    final store = context.read<AdminStore>();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(team == null ? 'New team' : 'Edit team', style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(controller: name, autofocus: team == null, decoration: const InputDecoration(labelText: 'Team name')),
              const SizedBox(height: 12),
              TextField(controller: description, decoration: const InputDecoration(labelText: 'Description (optional)')),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                children: [
                  for (final c in _palette)
                    GestureDetector(
                      onTap: () => setSheet(() => color = c),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppColors.hex(c),
                          shape: BoxShape.circle,
                          border: Border.all(color: c == color ? AppColors.ink : Colors.transparent, width: 2.5),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: 'Save',
                onPressed: () async {
                  final body = {
                    'name': name.text.trim(),
                    'description': description.text.trim().isEmpty ? null : description.text.trim(),
                    'color': color,
                  };
                  try {
                    if (team == null) {
                      await api.post('/teams', body);
                    } else {
                      await api.patch('/teams/${team.id}', body);
                    }
                    await store.refresh(quiet: true);
                    if (sheet.mounted) Navigator.pop(sheet);
                  } on ApiException catch (e) {
                    if (sheet.mounted) showMessage(sheet, e.message);
                  }
                },
              ),
              if (team != null)
                TextButton(
                  onPressed: () async {
                    try {
                      await api.delete('/teams/${team.id}');
                      await store.refresh(quiet: true);
                      if (sheet.mounted) Navigator.pop(sheet);
                    } on ApiException catch (e) {
                      if (sheet.mounted) showMessage(sheet, e.message);
                    }
                  },
                  child: const Text('Delete team (members become unassigned)', style: TextStyle(color: AppColors.offline)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
