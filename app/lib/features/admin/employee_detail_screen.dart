import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../state/admin_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';
import 'manage/employee_form_screen.dart';
import 'manage/pairing_code_sheet.dart';
import 'request_location_screen.dart';

class EmployeeDetailScreen extends StatefulWidget {
  const EmployeeDetailScreen({super.key, required this.employeeId});
  final int employeeId;

  @override
  State<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends State<EmployeeDetailScreen> {
  EmployeeDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await context.read<ApiClient>().get('/employees/${widget.employeeId}');
      if (!mounted) return;
      final detail = EmployeeDetail.fromJson(json as Map<String, dynamic>);
      context.read<AdminStore>().upsert(detail.employee);
      setState(() {
        _detail = detail;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _launch(Uri uri) async {
    if (!await launchUrl(uri) && mounted) showMessage(context, 'No app on this phone can open that.');
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AdminStore>();
    // The store carries realtime updates; the detail call adds devices and consent.
    final employee = store.byId(widget.employeeId) ?? _detail?.employee;
    final api = context.read<ApiClient>();

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              BackHeader(
                title: 'Employee Details',
                trailing: employee == null
                    ? null
                    : PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz_rounded),
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeFormScreen(existing: _detail)));
                            _load();
                          } else if (v == 'pair') {
                            await showPairingCodeSheet(context, employee);
                            _load();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit employee')),
                          PopupMenuItem(value: 'pair', child: Text('Pair a phone')),
                        ],
                      ),
              ),
              Expanded(
                child: employee == null
                    ? Center(
                        child: _error != null
                            ? Padding(padding: const EdgeInsets.all(24), child: ErrorBanner(message: _error!, onRetry: _load))
                            : const CircularProgressIndicator(color: AppColors.orange),
                      )
                    : RefreshIndicator(
                        color: AppColors.orange,
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                          children: [
                            _ProfileCard(
                              employee: employee,
                              api: api,
                              onRequest: () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => RequestLocationScreen(employeeId: employee.id)),
                              ),
                              onCall: employee.phone == null ? null : () => _launch(Uri(scheme: 'tel', path: employee.phone)),
                              onMessage: employee.phone == null ? null : () => _launch(Uri(scheme: 'sms', path: employee.phone)),
                            ),
                            const SizedBox(height: 14),
                            _LocationCard(
                              employee: employee,
                              onOpen: employee.lastLocation == null ? null : () => _viewOnMap(employee),
                            ),
                            const SizedBox(height: 14),
                            _SharingCard(detail: _detail, employee: employee),
                            const SizedBox(height: 22),
                            PrimaryButton(
                              label: 'View on Map',
                              icon: Icons.map_outlined,
                              onPressed: employee.lastLocation == null ? null : () => _viewOnMap(employee),
                            ),
                            if (employee.lastLocation == null)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Text(
                                  'No location received from this employee yet.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
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

  void _viewOnMap(Employee e) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    AdminShell.of(context).openMap(focusEmployeeId: e.id);
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.employee, required this.api, required this.onRequest, this.onCall, this.onMessage});

  final Employee employee;
  final ApiClient api;
  final VoidCallback onRequest;
  final VoidCallback? onCall;
  final VoidCallback? onMessage;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Hero(tag: 'avatar-${employee.id}', child: EmployeeAvatar(employee: employee, api: api, size: 96)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(employee.name, style: t.titleLarge),
                    if (employee.roleTitle != null) ...[
                      const SizedBox(height: 2),
                      Text(employee.roleTitle!, style: t.bodyLarge),
                    ],
                    const SizedBox(height: 10),
                    StatusPill.employee(employee.status),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _MetaChip(icon: Icons.badge_outlined, text: employee.code),
              const SizedBox(width: 8),
              if (employee.teamName != null)
                Flexible(child: _MetaChip(icon: Icons.groups_outlined, text: employee.teamName!, color: AppColors.hex(employee.teamColor))),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.hairline),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              children: [
                _Action(icon: Icons.location_on_outlined, label: 'Request\nLocation', onTap: onRequest),
                const VerticalDivider(color: AppColors.hairline, width: 1),
                _Action(icon: Icons.call_outlined, label: 'Call', onTap: onCall),
                const VerticalDivider(color: AppColors.hairline, width: 1),
                _Action(icon: Icons.chat_bubble_outline_rounded, label: 'Message', onTap: onMessage),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text, this.color = AppColors.muted});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: AppColors.orangeTint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.inkSoft))),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                IconDisc(icon: icon, size: 46),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.ink, height: 1.15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.employee, this.onOpen});

  final Employee employee;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final loc = employee.lastLocation;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on_rounded, color: AppColors.orange, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(loc?.source == 'request' ? 'Location (shared on request)' : 'Current Location', style: t.titleSmall),
                        const SizedBox(height: 4),
                        Text(
                          loc == null
                              ? 'No location yet'
                              : [
                                  if (loc.siteName != null) loc.siteName!,
                                  loc.address ?? 'Address unavailable',
                                ].join('\n'),
                          style: t.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  if (onOpen != null) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                ],
              ),
            ),
          ),
          if (loc != null) ...[
            const Divider(height: 1, indent: 16, endIndent: 16, color: AppColors.hairline),
            _Pair(
              left: _Cell(title: 'Latitude', value: latitude(loc.latitude)),
              right: _Cell(title: 'Longitude', value: longitude(loc.longitude)),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16, color: AppColors.hairline),
            _Pair(
              left: _Cell(icon: Icons.schedule_rounded, title: 'Last Updated', value: timeAgo(loc.recordedAt), small: true),
              right: _Cell(
                icon: Icons.gps_fixed_rounded,
                title: 'Accuracy',
                value: accuracy(loc.accuracyM),
                small: true,
                warn: loc.lowAccuracy,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Pair extends StatelessWidget {
  const _Pair({required this.left, required this.right});
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
        child: Row(
          children: [
            Expanded(child: left),
            const VerticalDivider(width: 1, color: AppColors.hairline, indent: 12, endIndent: 12),
            Expanded(child: right),
          ],
        ),
      );
}

class _Cell extends StatelessWidget {
  const _Cell({required this.title, required this.value, this.icon, this.small = false, this.warn = false});

  final String title;
  final String value;
  final IconData? icon;
  final bool small;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 24, color: AppColors.inkSoft), const SizedBox(width: 10)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, color: AppColors.inkSoft)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: small ? 14.5 : 17,
                    fontWeight: small ? FontWeight.w500 : FontWeight.w700,
                    color: warn ? AppColors.inTransit : AppColors.ink,
                  ),
                ),
                if (warn) const Text('Weak GPS signal', style: TextStyle(fontSize: 11.5, color: AppColors.inTransit)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SharingCard extends StatelessWidget {
  const _SharingCard({required this.detail, required this.employee});

  final EmployeeDetail? detail;
  final Employee employee;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final permission = detail?.permission;
    final device = detail?.activeDevice;
    final health = device?.permissionState;
    final issues = <String>[
      if (health != null && health['services_enabled'] == false) 'Location turned off',
      if (health != null && health['background'] == false) 'No background permission',
      if (health != null && health['battery_unrestricted'] == false) 'Battery optimisation on',
      if (health != null && health['notifications'] == false) 'Notifications blocked',
    ];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Location sharing', style: t.titleSmall),
              const Spacer(),
              StatusPill(
                label: employee.sharingEnabled ? 'Sharing' : 'Paused',
                color: employee.sharingEnabled ? AppColors.onSite : AppColors.muted,
                solid: false,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _line(Icons.smartphone_rounded, device == null
              ? 'No paired phone'
              : '${device.label ?? 'Paired phone'} · seen ${timeAgo(device.lastSeenAt).toLowerCase()}'),
          if (device?.batteryLevel != null) _line(Icons.battery_std_rounded, 'Battery ${device!.batteryLevel}%'),
          if (permission?.consentedAt != null) _line(Icons.verified_user_outlined, 'Consent given ${dateTime(permission!.consentedAt!)}'),
          _line(Icons.history_rounded, permission?.historyEnabled == true ? 'Location history on' : 'Location history off'),
          if (device != null && !device.hasPush) _line(Icons.notifications_off_outlined, 'Push not registered — requests reach the phone only while the app is open'),
          for (final issue in issues) _line(Icons.warning_amber_rounded, issue, color: AppColors.inTransit),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text, {Color color = AppColors.inkSoft}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, color: color))),
          ],
        ),
      );
}
