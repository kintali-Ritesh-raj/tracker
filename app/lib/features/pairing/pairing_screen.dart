import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// First-run screen. A phone is trusted only after redeeming a one-time code
/// issued by SLG management, so there is no sign-up or password.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.onPaired, this.notice});

  final Future<void> Function(Session) onPaired;
  final String? notice;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  static const _defaultServer = String.fromEnvironment('SERVER_URL', defaultValue: 'https://');
  static const _allowInsecure = bool.fromEnvironment('ALLOW_INSECURE');

  final _server = TextEditingController(text: _defaultServer);
  final _code = TextEditingController();
  final _label = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    _label.dispose();
    super.dispose();
  }

  String? _validateServer(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasAuthority) return 'Enter the server address, for example https://track.slg.in';
    final local = RegExp(r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && (local || _allowInsecure))) {
      return 'Use an https:// address. Plain http is only allowed on a local network.';
    }
    return null;
  }

  Future<void> _pair() async {
    final serverError = _validateServer(_server.text);
    final code = _code.text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (serverError != null) return setState(() => _error = serverError);
    if (code.length < 6) return setState(() => _error = 'Enter the 8-character pairing code.');

    setState(() {
      _busy = true;
      _error = null;
    });
    final server = _server.text.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final info = await PackageInfo.fromPlatform();
      final res = await http
          .post(
            Uri.parse('$server/api/v1/devices/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'code': code,
              'label': _label.text.trim().isEmpty ? null : _label.text.trim(),
              'platform': Platform.operatingSystem,
              'app_version': info.version,
            }),
          )
          .timeout(const Duration(seconds: 15));
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        setState(() => _error = body['detail'] is String ? body['detail'] as String : 'Pairing failed.');
        return;
      }
      HapticFeedback.mediumImpact();
      await widget.onPaired(Session(
        serverUrl: server,
        token: body['token'] as String,
        role: body['role'] == 'admin' ? DeviceRole.admin : DeviceRole.employee,
        deviceId: (body['device'] as Map<String, dynamic>)['id'] as int,
        employeeId: (body['employee'] as Map<String, dynamic>?)?['id'] as int?,
      ));
    } on TimeoutException {
      setState(() => _error = 'The server did not respond. Check the address and your connection.');
    } on SocketException {
      setState(() => _error = 'Could not reach the server. Check the address and your connection.');
    } on FormatException {
      setState(() => _error = 'That address did not respond like an SLG FieldTrack server.');
    } catch (e) {
      setState(() => _error = 'Pairing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: AppBackground(
        skyline: true,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
            children: [
              const Center(child: SlgLogo(height: 64)),
              const SizedBox(height: 36),
              Text('Pair this phone', style: t.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Enter the server address and the one-time code from SLG management. '
                'Admins get their code from the server operator; employees get theirs from an admin.',
                style: t.bodyMedium,
              ),
              if (widget.notice != null) ...[
                const SizedBox(height: 16),
                ErrorBanner(message: widget.notice!),
              ],
              const SizedBox(height: 24),
              GlassCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Server address', prefixIcon: Icon(Icons.dns_outlined)),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      autocorrect: false,
                      maxLength: 9,
                      style: const TextStyle(fontSize: 22, letterSpacing: 6, fontWeight: FontWeight.w700),
                      decoration: const InputDecoration(
                        labelText: 'Pairing code',
                        counterText: '',
                        prefixIcon: Icon(Icons.key_rounded),
                      ),
                      onSubmitted: (_) => _pair(),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _label,
                      decoration: const InputDecoration(
                        labelText: 'Phone name (optional)',
                        hintText: 'e.g. Supervisor phone',
                        prefixIcon: Icon(Icons.smartphone_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: _error == null
                    ? const SizedBox(height: 20)
                    : Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: ErrorBanner(message: _error!)),
              ),
              PrimaryButton(label: 'Pair Device', icon: Icons.link_rounded, busy: _busy, onPressed: _pair),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Codes work once and expire. The phone stores its key in secure storage.', style: t.bodySmall),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
