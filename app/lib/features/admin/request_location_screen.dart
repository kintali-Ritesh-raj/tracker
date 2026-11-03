import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/admin_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';

/// Sends a location request and follows it live until it resolves.
class RequestLocationScreen extends StatefulWidget {
  const RequestLocationScreen({super.key, this.employeeId});

  /// Preselected employee; when null the admin picks one first.
  final int? employeeId;

  @override
  State<RequestLocationScreen> createState() => _RequestLocationScreenState();
}

class _RequestLocationScreenState extends State<RequestLocationScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  StreamSubscription<LocationRequest>? _sub;
  Timer? _ticker;
  int? _employeeId;
  LocationRequest? _request;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _employeeId = widget.employeeId;
    _sub = context.read<AdminStore>().requestUpdates.listen((r) {
      if (r.id == _request?.id && mounted) setState(() => _request = r);
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _request?.status == RequestStatus.pending) setState(() {});
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final json = await context.read<ApiClient>().post('/location-requests', {'employee_id': _employeeId});
      setState(() => _request = LocationRequest.fromJson(json as Map<String, dynamic>));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Fallback in case a socket event was missed while reconnecting.
  Future<void> _poll() async {
    final id = _request?.id;
    if (id == null) return;
    try {
      final json = await context.read<ApiClient>().get('/location-requests/$id');
      if (mounted) setState(() => _request = LocationRequest.fromJson(json as Map<String, dynamic>));
    } catch (_) {}
  }

  Future<void> _pickEmployee() async {
    final store = context.read<AdminStore>();
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EmployeePicker(employees: store.employees, api: context.read<ApiClient>()),
    );
    if (picked != null) {
      setState(() {
        _employeeId = picked;
        _request = null;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    final api = context.read<ApiClient>();
    final employee = _employeeId == null ? null : store.byId(_employeeId!);
    final t = Theme.of(context).textTheme;
    final req = _request;
    final firstName = employee?.name.split(' ').first ?? 'the employee';

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'Request Location'),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    const SizedBox(height: 12),
                    Center(child: _Beacon(animation: _pulse, status: req?.status, awaiting: req?.awaitingFreshFix ?? false)),
                    const SizedBox(height: 28),
                    Text(_title(req), textAlign: TextAlign.center, style: t.titleLarge),
                    const SizedBox(height: 10),
                    Text(_message(req, employee?.name ?? 'the employee', firstName),
                        textAlign: TextAlign.center, style: t.bodyLarge),
                    const SizedBox(height: 26),
                    if (employee != null)
                      GlassCard(
                        onTap: req == null || !req.isOpen ? _pickEmployee : null,
                        child: Row(
                          children: [
                            EmployeeAvatar(employee: employee, api: api, size: 56),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(employee.name, style: t.titleMedium),
                                  Text(employee.roleTitle ?? employee.code, style: t.bodyMedium),
                                ],
                              ),
                            ),
                            if (req != null) StatusPill.request(req.status) else const Icon(Icons.swap_vert_rounded, color: AppColors.muted),
                          ],
                        ),
                      )
                    else
                      GlassCard(
                        onTap: _pickEmployee,
                        child: Row(
                          children: [
                            const IconDisc(icon: Icons.person_search_rounded, size: 56),
                            const SizedBox(width: 14),
                            Expanded(child: Text('Select an employee', style: t.titleMedium)),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                    if (req?.location != null) ...[
                      const SizedBox(height: 14),
                      _FixCard(fix: req!.location!, fresh: req.fulfilledAt != null),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      ErrorBanner(message: _error!),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: _button(req, employee),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(LocationRequest? req, Employee? employee) {
    if (req != null && req.status == RequestStatus.pending) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                side: const BorderSide(color: AppColors.orangeSoft),
                foregroundColor: AppColors.orangeDeep,
              ),
              onPressed: _poll,
              child: const Text('Check status', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
    }
    if (req?.location != null && req!.status == RequestStatus.approved) {
      return PrimaryButton(
        label: 'View on Map',
        icon: Icons.map_outlined,
        onPressed: () {
          Navigator.of(context).popUntil((r) => r.isFirst);
          AdminShell.of(context).openMap(focusEmployeeId: req.employeeId);
        },
      );
    }
    return PrimaryButton(
      label: req == null ? 'Send Request' : 'Send Again',
      icon: Icons.near_me_rounded,
      busy: _sending,
      onPressed: employee == null ? null : _send,
    );
  }

  String _title(LocationRequest? r) {
    if (r == null) return 'Request Current Location';
    return switch (r.status) {
      RequestStatus.pending => 'Waiting for response',
      RequestStatus.approved => r.awaitingFreshFix ? 'Getting a fresh fix' : 'Location received',
      RequestStatus.declined => 'Request declined',
      RequestStatus.unavailable => 'Location unavailable',
    };
  }

  String _message(LocationRequest? r, String name, String first) {
    if (r == null) {
      return 'Send a location request to $name. They will be notified to share their current location.';
    }
    switch (r.status) {
      case RequestStatus.pending:
        final left = r.expiresAt.difference(DateTime.now());
        final secs = left.isNegative ? 0 : left.inSeconds;
        return '$first has been notified and can approve or decline. Expires in ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}.';
      case RequestStatus.approved:
        if (r.awaitingFreshFix) {
          return r.location == null
              ? '$first shares location continuously. Their phone is being asked for a fresh fix.'
              : 'Showing $first\'s latest shared location. A fresh fix has been requested from their phone.';
        }
        return r.autoApproved
            ? 'Latest location from $first\'s continuous sharing.'
            : '$first approved and shared their location.';
      case RequestStatus.declined:
        return '$first chose not to share their location right now.';
      case RequestStatus.unavailable:
        return 'The phone did not respond in time, is switched off, or is not paired. Try calling $first.';
    }
  }
}

class _Beacon extends StatelessWidget {
  const _Beacon({required this.animation, required this.status, required this.awaiting});

  final Animation<double> animation;
  final RequestStatus? status;
  final bool awaiting;

  @override
  Widget build(BuildContext context) {
    final pulsing = status == null || status == RequestStatus.pending || awaiting;
    final color = status == null ? AppColors.orange : AppColors.request(status!);
    final icon = switch (status) {
      RequestStatus.approved => awaiting ? Icons.near_me_rounded : Icons.check_rounded,
      RequestStatus.declined => Icons.close_rounded,
      RequestStatus.unavailable => Icons.portable_wifi_off_rounded,
      _ => Icons.near_me_rounded,
    };
    return SizedBox(
      width: 210,
      height: 210,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => CustomPaint(
          painter: _RingsPainter(progress: pulsing ? animation.value : 0, color: color),
          child: child,
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 128,
            height: 128,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [Colors.white, color.withValues(alpha: 0.12)]),
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 30, offset: const Offset(0, 10))],
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(icon, key: ValueKey(icon), size: 64, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1;
      final r = 66 + (maxR - 66) * p;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: (1 - p) * 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingsPainter old) => old.progress != progress || old.color != color;
}

class _FixCard extends StatelessWidget {
  const _FixCard({required this.fix, required this.fresh});

  final LocationFix fix;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.location_on_rounded, color: AppColors.orange, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fix.siteName ?? fix.address ?? '${latitude(fix.latitude)}, ${longitude(fix.longitude)}', style: t.titleSmall),
                const SizedBox(height: 4),
                Text('${fresh ? 'Fresh fix' : 'Latest fix'} · ${timeAgo(fix.recordedAt)} · ${accuracy(fix.accuracyM)}', style: t.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmployeePicker extends StatefulWidget {
  const _EmployeePicker({required this.employees, required this.api});

  final List<Employee> employees;
  final ApiClient api;

  @override
  State<_EmployeePicker> createState() => _EmployeePickerState();
}

class _EmployeePickerState extends State<_EmployeePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final list = widget.employees
        .where((e) => _q.isEmpty || e.name.toLowerCase().contains(_q) || e.code.toLowerCase().contains(_q))
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search name or ID', prefixIcon: Icon(Icons.search_rounded)),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) {
                final e = list[i];
                return ListTile(
                  leading: EmployeeAvatar(employee: e, api: widget.api, size: 40),
                  title: Text(e.name),
                  subtitle: Text(e.teamName ?? e.code),
                  trailing: StatusPill.employee(e.status, dense: true),
                  onTap: () => Navigator.of(context).pop(e.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
