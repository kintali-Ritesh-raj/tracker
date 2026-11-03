import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';
import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Issues a one-time pairing code. Pass [employee] for an employee phone, or
/// null to pair another admin phone.
Future<void> showPairingCodeSheet(BuildContext context, Employee? employee) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PairingCodeSheet(employee: employee),
  );
}

class _PairingCodeSheet extends StatefulWidget {
  const _PairingCodeSheet({this.employee});
  final Employee? employee;

  @override
  State<_PairingCodeSheet> createState() => _PairingCodeSheetState();
}

class _PairingCodeSheetState extends State<_PairingCodeSheet> {
  String? _code;
  DateTime? _expires;
  String? _error;

  @override
  void initState() {
    super.initState();
    _issue();
  }

  Future<void> _issue() async {
    setState(() => _error = null);
    try {
      final json = await context.read<ApiClient>().post('/pairing-codes', {
        'role': widget.employee == null ? 'admin' : 'employee',
        'employee_id': widget.employee?.id,
      }) as Map<String, dynamic>;
      setState(() {
        _code = json['code'] as String;
        _expires = DateTime.parse(json['expires_at'] as String).toLocal();
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final server = context.read<Session>().serverUrl;
    final code = _code;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.employee == null ? 'Pair an admin phone' : 'Pair ${widget.employee!.name}\'s phone', style: t.titleLarge),
            const SizedBox(height: 8),
            Text(
              widget.employee == null
                  ? 'On the new admin phone, open SLG FieldTrack and enter this server address and code. The code works once.'
                  : 'On the employee\'s phone, install SLG FieldTrack and enter this server address and code. Pairing a new phone unpairs any previous one.',
              textAlign: TextAlign.center,
              style: t.bodyMedium,
            ),
            const SizedBox(height: 20),
            if (_error != null) ErrorBanner(message: _error!, onRetry: _issue),
            if (code == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: AppColors.orange)),
            if (code != null) ...[
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  showMessage(context, 'Code copied');
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(color: AppColors.orangeTint, borderRadius: BorderRadius.circular(18)),
                  child: Column(
                    children: [
                      SelectableText(
                        '${code.substring(0, 4)} ${code.substring(4)}',
                        style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 6, color: AppColors.orangeDeep),
                      ),
                      const SizedBox(height: 6),
                      Text('Tap to copy · valid until ${dateTime(_expires!)}', style: t.bodySmall),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.dns_outlined, size: 18, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Expanded(child: SelectableText(server, style: t.bodyMedium)),
                ],
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
            ),
          ],
        ),
      ),
    );
  }
}
