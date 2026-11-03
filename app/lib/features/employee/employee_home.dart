import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/realtime.dart';
import '../../services/location_service.dart';
import '../../services/push_service.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'request_prompt.dart';

/// The employee's own app: consent to share, see exactly what is shared,
/// answer location requests, and fix anything that blocks tracking.
class EmployeeHome extends StatefulWidget {
  const EmployeeHome({super.key});

  @override
  State<EmployeeHome> createState() => _EmployeeHomeState();
}

class _EmployeeHomeState extends State<EmployeeHome> with WidgetsBindingObserver {
  late final ApiClient _api = context.read<ApiClient>();
  late final RealtimeConnection _realtime = context.read<RealtimeConnection>();
  late final LocationTracker _tracker = LocationTracker(_api);

  Employee? _me;
  Permission? _permission;
  AppSettings? _settings;
  LocationHealth? _health;
  List<LocationRequest> _requests = [];
  String? _error;
  bool _toggling = false;
  bool _prompting = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tracker.addListener(_onTracker);
    _subs.add(_realtime.events.listen(_onEvent));
    _subs.add(PushService.messages.listen((m) {
      if (m.type == 'location_refresh' && m.requestId != null) {
        LocationService.answerRequest(_api, m.requestId!);
      } else {
        _loadRequests(prompt: true);
      }
    }));
    _realtime.connect();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _tracker.removeListener(_onTracker);
    _tracker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      _refreshHealth();
      _loadRequests(prompt: true);
      _realtime.reconnectNow();
      _tracker.flush();
    }
  }

  void _onTracker() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    await _refreshHealth();
    try {
      final results = await Future.wait([_api.get('/me'), _api.get('/me/permission'), _api.get('/settings')]);
      setState(() {
        _me = Employee.fromJson(results[0] as Map<String, dynamic>);
        _permission = Permission.fromJson(results[1] as Map<String, dynamic>);
        _settings = AppSettings.fromJson(results[2] as Map<String, dynamic>);
        _error = null;
      });
      if (_permission!.sharingEnabled) await _startTracking();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
    await _loadRequests(prompt: true);
  }

  Future<void> _refreshHealth() async {
    final h = await LocationService.health();
    if (mounted) setState(() => _health = h);
  }

  Future<void> _loadRequests({bool prompt = false}) async {
    try {
      final list = (await _api.get('/me/location-requests') as List)
          .map((j) => LocationRequest.fromJson(j as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _requests = list);
      for (final r in list.where((r) => r.awaitingFreshFix)) {
        LocationService.answerRequest(_api, r.id).then((_) => _loadRequests());
      }
      final pending = list.where((r) => r.status == RequestStatus.pending).firstOrNull;
      if (prompt && pending != null) _prompt(pending);
    } on ApiException {
      // Shown via the main error banner when relevant.
    }
  }

  void _onEvent(RealtimeEvent e) {
    switch (e.type) {
      case 'location_request.created':
        final req = LocationRequest.fromJson(e.data);
        setState(() => _requests = [req, ..._requests.where((r) => r.id != req.id)]);
        if (_lifecycle != AppLifecycleState.resumed) {
          PushService.showRequestNotification(req.id);
        } else {
          _prompt(req);
        }
      case 'location_request.updated':
        _loadRequests();
      case 'location.refresh':
        // Covered by the employee's consent to continuous sharing.
        final id = e.data['request_id'] as int?;
        if (id != null) LocationService.answerRequest(_api, id).then((_) => _loadRequests());
    }
  }

  Future<void> _prompt(LocationRequest req) async {
    if (_prompting || !mounted) return;
    _prompting = true;
    HapticFeedback.heavyImpact();
    await showRequestPrompt(context, req, onDone: _loadRequests);
    _prompting = false;
  }

  Future<void> _startTracking() async {
    final h = _health ?? await LocationService.health();
    if (!h.canTrack) return;
    await _tracker.start(
      intervalSeconds: _settings?.trackingIntervalSeconds ?? 60,
      distanceFilterM: _settings?.trackingDistanceFilterM ?? 25,
    );
  }

  Future<void> _setSharing(bool enable) async {
    if (enable) {
      final consent = await showDialog<bool>(context: context, builder: (_) => const _ConsentDialog());
      if (consent != true) return;
    }
    setState(() => _toggling = true);
    try {
      if (enable) {
        if (!await LocationService.requestForeground()) {
          if (mounted) showMessage(context, 'Location permission is needed to share your location.');
          return;
        }
        await LocationService.requestNotifications();
        await LocationService.requestBackground();
        await LocationService.requestBatteryExemption();
        await _refreshHealth();
      }
      final json = await _api.put('/me/permission', {
        'sharing_enabled': enable,
        'background_enabled': enable && (_health?.background ?? false),
        'history_enabled': _permission?.historyEnabled ?? true,
      });
      setState(() => _permission = Permission.fromJson(json as Map<String, dynamic>));
      if (enable) {
        await _startTracking();
      } else {
        await _tracker.stop();
        await FixOutbox.clear();
      }
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _setHistory(bool enabled) async {
    try {
      final json = await _api.put('/me/permission', {
        'sharing_enabled': _permission?.sharingEnabled ?? false,
        'background_enabled': _permission?.backgroundEnabled ?? false,
        'history_enabled': enabled,
      });
      setState(() => _permission = Permission.fromJson(json as Map<String, dynamic>));
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unpair this phone?'),
        content: const Text('Location sharing stops and you will need a new code from your supervisor to pair again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Unpair')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final unpair = context.read<VoidCallback>();
    try {
      await _api.put('/me/permission', {'sharing_enabled': false, 'background_enabled': false, 'history_enabled': true});
    } catch (_) {}
    await _tracker.stop();
    await FixOutbox.clear();
    unpair();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final me = _me;
    final sharing = _permission?.sharingEnabled ?? false;
    final open = _requests.where((r) => r.status == RequestStatus.pending).toList();

    return Scaffold(
      body: AppBackground(
        skyline: true,
        child: SafeArea(
          child: RefreshIndicator(
            color: AppColors.orange,
            onRefresh: _bootstrap,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Row(
                  children: [
                    const SlgLogo(height: 50),
                    const Spacer(),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz_rounded),
                      onSelected: (v) => v == 'unpair' ? _unpair() : null,
                      itemBuilder: (_) => const [PopupMenuItem(value: 'unpair', child: Text('Unpair this phone'))],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(greeting(DateTime.now()), style: t.headlineMedium?.copyWith(fontSize: 24)),
                if (me != null) Text('${me.name}${me.roleTitle == null ? '' : ' · ${me.roleTitle}'}', style: t.bodyLarge),
                if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(message: _error!, onRetry: _bootstrap)],
                for (final r in open) ...[
                  const SizedBox(height: 14),
                  _RequestBanner(request: r, onTap: () => _prompt(r)),
                ],
                const SizedBox(height: 18),
                _SharingCard(
                  sharing: sharing,
                  busy: _toggling,
                  tracker: _tracker,
                  health: _health,
                  onChanged: _permission == null ? null : _setSharing,
                ),
                if (_health != null && sharing && !_health!.allGood) ...[
                  const SizedBox(height: 14),
                  _HealthCard(health: _health!, onFixed: () async {
                    await _refreshHealth();
                    if (sharing && !_tracker.isRunning) await _startTracking();
                  }),
                ],
                const SizedBox(height: 14),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('What SLG can see', style: t.titleSmall),
                      const SizedBox(height: 8),
                      _bullet('Your GPS position, accuracy and time while sharing is on'),
                      _bullet('Which client site you are at, if any'),
                      _bullet('Your phone\'s battery level and whether location is allowed'),
                      _bullet('Nothing while sharing is paused, unless you approve a request'),
                      const Divider(height: 24, color: AppColors.hairline),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Keep location history'),
                        subtitle: const Text('Lets supervisors view your route for attendance reports'),
                        value: _permission?.historyEnabled ?? true,
                        onChanged: _permission == null ? null : _setHistory,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(padding: EdgeInsets.only(top: 7), child: CircleAvatar(radius: 2.5, backgroundColor: AppColors.orange)),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, color: AppColors.inkSoft))),
          ],
        ),
      );
}

class _SharingCard extends StatelessWidget {
  const _SharingCard({required this.sharing, required this.busy, required this.tracker, required this.health, this.onChanged});

  final bool sharing;
  final bool busy;
  final LocationTracker tracker;
  final LocationHealth? health;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fix = tracker.lastFix;
    final (label, color, detail) = _status();
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: sharing ? AppColors.orange : AppColors.orangeSoft,
                  shape: BoxShape.circle,
                  boxShadow: sharing ? AppShadow.button : null,
                ),
                child: Icon(sharing ? Icons.my_location_rounded : Icons.location_disabled_rounded,
                    color: sharing ? Colors.white : AppColors.orange, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Share my location', style: t.titleMedium),
                    const SizedBox(height: 4),
                    StatusPill(label: label, color: color, solid: false, dense: true),
                  ],
                ),
              ),
              busy
                  ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.orange))
                  : Switch(value: sharing, onChanged: onChanged),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 12),
            Text(detail, style: t.bodyMedium),
          ],
          if (sharing && fix != null) ...[
            const Divider(height: 26, color: AppColors.hairline),
            Row(
              children: [
                Expanded(child: _metric('Last fix', clockTime(fix.timestamp.toLocal()))),
                Expanded(child: _metric('Accuracy', accuracy(fix.accuracy), warn: fix.accuracy > 100)),
                Expanded(
                  child: _metric(
                    'Uploaded',
                    tracker.queued > 0 ? '${tracker.queued} waiting' : (tracker.lastUploadAt == null ? '—' : timeAgo(tracker.lastUploadAt)),
                    warn: tracker.queued > 0,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  (String, Color, String?) _status() {
    if (!sharing) return ('Paused', AppColors.muted, 'SLG cannot see your location. Turn this on when you start your shift.');
    if (tracker.problem != null) return ('Needs attention', AppColors.offline, tracker.problem);
    if (health != null && !health!.canTrack) {
      return ('Blocked', AppColors.offline, 'Location is off or not allowed on this phone. Use the checklist below.');
    }
    if (!tracker.online) {
      return ('Offline', AppColors.inTransit, 'No internet. Positions are saved on the phone and sent when you are back online.');
    }
    return switch (tracker.state) {
      TrackerState.tracking => ('Sharing live', AppColors.onSite, null),
      TrackerState.waitingForGps => ('Waiting for GPS', AppColors.inTransit, 'Weak or no GPS signal. Move near a window or outdoors.'),
      TrackerState.starting => ('Starting…', AppColors.inTransit, null),
      TrackerState.error => ('Needs attention', AppColors.offline, tracker.problem),
      TrackerState.stopped => ('Not running', AppColors.inTransit, 'Sharing is on but this phone is not sending. Pull down to retry.'),
    };
  }

  Widget _metric(String label, String value, {bool warn = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: warn ? AppColors.inTransit : AppColors.ink)),
        ],
      );
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.health, required this.onFixed});

  final LocationHealth health;
  final Future<void> Function() onFixed;

  @override
  Widget build(BuildContext context) {
    final rows = <(bool, String, String, Future<void> Function())>[
      (health.servicesEnabled, 'Location is on', 'Turn on location', LocationService.openLocationSettings),
      (health.foreground, 'Location allowed', 'Allow location', () => LocationService.requestForeground()),
      (health.background, 'Allowed all the time', 'Choose “Allow all the time”', () => LocationService.requestBackground()),
      (health.precise, 'Precise location', 'Turn on precise location', () => LocationService.requestForeground()),
      (health.notifications, 'Notifications allowed', 'Allow notifications', LocationService.requestNotifications),
      (health.batteryUnrestricted, 'No battery restriction', 'Remove battery restriction', LocationService.requestBatteryExemption),
    ];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Keep sharing reliable', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Android may stop location updates in the background unless these are set.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final (ok, okLabel, fixLabel, fix) in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                  color: ok ? AppColors.onSite : AppColors.inTransit),
              title: Text(ok ? okLabel : fixLabel),
              trailing: ok
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await fix();
                        await onFixed();
                      },
                      child: const Text('Fix'),
                    ),
            ),
        ],
      ),
    );
  }
}

class _RequestBanner extends StatelessWidget {
  const _RequestBanner({required this.request, required this.onTap});

  final LocationRequest request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      child: Row(
        children: [
          const IconDisc(icon: Icons.near_me_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Location requested', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                Text('Sent ${timeAgo(request.createdAt).toLowerCase()} · tap to respond', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Share your location with SLG?'),
      content: const Text(
        'While sharing is on, SLG FieldTrack sends your GPS position to SLG management every minute or so, '
        'including when the app is in the background. A notification stays visible the whole time. '
        'You can pause sharing here at any time.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('I agree, share'),
        ),
      ],
    );
  }
}
