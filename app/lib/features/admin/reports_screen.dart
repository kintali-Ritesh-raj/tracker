import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';

/// Attendance and site visits for one day, derived from real stored fixes.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime _day = DateTime.now();
  int _tab = 0;
  List<Map<String, dynamic>> _attendance = [];
  List<Map<String, dynamic>> _visits = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    final query = {
      'date': '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}',
      'tz_offset': '${_day.timeZoneOffset.inMinutes}',
    };
    try {
      final results = await Future.wait([
        api.get('/reports/attendance', query: query),
        api.get('/reports/site-visits', query: query),
      ]);
      setState(() {
        _attendance = (results[0] as List).cast<Map<String, dynamic>>();
        _visits = (results[1] as List).cast<Map<String, dynamic>>();
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _day = picked);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final present = _attendance.where((r) => r['first_seen'] != null).length;
    final onSiteMinutes = _attendance.fold<int>(0, (s, r) => s + (r['on_site_minutes'] as int));

    return AppBackground(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            BackHeader(
              title: 'Reports',
              onBack: () => AdminShell.of(context).select(0),
              trailing: TextButton.icon(
                onPressed: _pickDay,
                icon: const Icon(Icons.calendar_today_rounded, size: 18, color: AppColors.orangeDeep),
                label: Text(headerDate(_day), style: const TextStyle(color: AppColors.orangeDeep, fontWeight: FontWeight.w600)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _Kpi(label: 'Reported in', value: '$present / ${_attendance.length}'),
                  const SizedBox(width: 10),
                  _Kpi(label: 'Site visits', value: '${_visits.length}'),
                  const SizedBox(width: 10),
                  _Kpi(label: 'Time on site', value: minutes(onSiteMinutes)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: AppColors.orange,
                  selectedForegroundColor: Colors.white,
                  backgroundColor: Colors.white,
                ),
                segments: const [
                  ButtonSegment(value: 0, label: Text('Attendance')),
                  ButtonSegment(value: 1, label: Text('Site visits')),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            ),
            const SizedBox(height: 10),
            if (_error != null) Padding(padding: const EdgeInsets.all(16), child: ErrorBanner(message: _error!, onRetry: _load)),
            Expanded(
              child: RefreshIndicator(
                color: AppColors.orange,
                onRefresh: _load,
                child: _loading && _attendance.isEmpty
                    ? const Center(child: CircularProgressIndicator(color: AppColors.orange))
                    : _tab == 0
                        ? _attendanceList(t)
                        : _visitList(t),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _attendanceList(TextTheme t) {
    if (_attendance.isEmpty) {
      return ListView(children: const [
        EmptyState(icon: Icons.event_busy_rounded, title: 'No employees', message: 'Attendance appears once employees share their location.'),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
      itemCount: _attendance.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final r = _attendance[i];
        final first = r['first_seen'] == null ? null : DateTime.parse(r['first_seen'] as String).toLocal();
        final last = r['last_seen'] == null ? null : DateTime.parse(r['last_seen'] as String).toLocal();
        final sites = (r['sites'] as List).cast<String>();
        return GlassCard(
          radius: AppRadius.tile,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r['employee_name'] as String, style: t.titleSmall),
                    Text(
                      first == null ? 'No location reported' : '${clockTime(first)} – ${clockTime(last!)}${sites.isEmpty ? '' : ' · ${sites.join(', ')}'}',
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(minutes(r['on_site_minutes'] as int), style: t.titleSmall?.copyWith(color: AppColors.orangeDeep)),
                  Text('on site', style: t.bodySmall),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _visitList(TextTheme t) {
    if (_visits.isEmpty) {
      return ListView(children: const [
        EmptyState(icon: Icons.apartment_rounded, title: 'No site visits', message: 'Visits are recorded when a shared location falls inside a site\'s geofence.'),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
      itemCount: _visits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final v = _visits[i];
        final arrived = DateTime.parse(v['arrived_at'] as String).toLocal();
        final left = DateTime.parse(v['left_at'] as String).toLocal();
        return GlassCard(
          radius: AppRadius.tile,
          child: Row(
            children: [
              const IconDisc(icon: Icons.apartment_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v['site_name'] as String, style: t.titleSmall),
                    Text('${v['employee_name']} · ${clockTime(arrived)} – ${clockTime(left)}', style: t.bodySmall),
                  ],
                ),
              ),
              Text(minutes(v['minutes'] as int), style: t.titleSmall),
            ],
          ),
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
        child: GlassCard(
          radius: AppRadius.tile,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          child: Column(
            children: [
              FittedBox(child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.ink))),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
        ),
      );
}
