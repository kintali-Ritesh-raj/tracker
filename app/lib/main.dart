import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/realtime.dart';
import 'core/session.dart';
import 'features/admin/admin_shell.dart';
import 'features/employee/employee_home.dart';
import 'features/pairing/pairing_screen.dart';
import 'services/push_service.dart';
import 'state/admin_store.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  await PushService.initialize();
  final session = await SessionStore.load();
  runApp(FieldTrackApp(initialSession: session));
}

class FieldTrackApp extends StatefulWidget {
  const FieldTrackApp({super.key, this.initialSession});
  final Session? initialSession;

  @override
  State<FieldTrackApp> createState() => _FieldTrackAppState();
}

class _FieldTrackAppState extends State<FieldTrackApp> {
  Session? _session;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _session = widget.initialSession;
  }

  Future<void> _paired(Session session) async {
    await SessionStore.save(session);
    setState(() {
      _session = session;
      _notice = null;
    });
  }

  Future<void> _unpair({String? reason}) async {
    if (_session == null) return;
    await SessionStore.clear();
    setState(() {
      _session = null;
      _notice = reason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return MaterialApp(
        title: 'SLG FieldTrack',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: PairingScreen(onPaired: _paired, notice: _notice),
      );
    }
    return _SessionScope(
      key: ValueKey('${session.role.name}:${session.deviceId}'),
      session: session,
      onRevoked: () => _unpair(reason: 'This phone was unpaired by SLG management. Ask an admin for a new pairing code.'),
      onUnpair: () => _unpair(),
    );
  }
}

/// Owns the API client and socket for one paired session.
class _SessionScope extends StatefulWidget {
  const _SessionScope({super.key, required this.session, required this.onRevoked, required this.onUnpair});

  final Session session;
  final VoidCallback onRevoked;
  final VoidCallback onUnpair;

  @override
  State<_SessionScope> createState() => _SessionScopeState();
}

class _SessionScopeState extends State<_SessionScope> {
  late final ApiClient api;
  late final RealtimeConnection realtime;
  AdminStore? store;

  @override
  void initState() {
    super.initState();
    api = ApiClient(widget.session)..onUnauthorized = widget.onRevoked;
    realtime = RealtimeConnection(widget.session);
    realtime.events.where((e) => e.type == 'unauthorized').listen((_) => widget.onRevoked());
    if (widget.session.isAdmin) {
      store = AdminStore(api, realtime)..start();
    }
    PushService.registerDevice(api);
  }

  @override
  void dispose() {
    store?.dispose();
    realtime.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<RealtimeConnection>.value(value: realtime),
        Provider<Session>.value(value: widget.session),
        Provider<VoidCallback>.value(value: widget.onUnpair),
        if (store != null) ChangeNotifierProvider<AdminStore>.value(value: store!),
      ],
      // Providers sit above the navigator so pushed routes and dialogs can read them.
      child: MaterialApp(
        title: 'SLG FieldTrack',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: widget.session.isAdmin ? AdminShell(key: AdminShell.globalKey) : const EmployeeHome(),
      ),
    );
  }
}
