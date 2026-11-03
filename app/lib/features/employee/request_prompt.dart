import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../services/location_service.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Full-height sheet asking the employee to approve or decline one request.
Future<void> showRequestPrompt(BuildContext context, LocationRequest request, {required VoidCallback onDone}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    builder: (_) => _RequestPrompt(request: request, onDone: onDone),
  );
}

class _RequestPrompt extends StatefulWidget {
  const _RequestPrompt({required this.request, required this.onDone});

  final LocationRequest request;
  final VoidCallback onDone;

  @override
  State<_RequestPrompt> createState() => _RequestPromptState();
}

class _RequestPromptState extends State<_RequestPrompt> {
  bool _approving = false;
  bool _declining = false;
  String? _error;

  Future<void> _approve() async {
    setState(() {
      _approving = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    if (!await LocationService.requestForeground()) {
      setState(() {
        _approving = false;
        _error = 'Allow location access so your position can be shared.';
      });
      return;
    }
    final error = await LocationService.answerRequest(api, widget.request.id);
    if (!mounted) return;
    if (error == null) {
      widget.onDone();
      Navigator.of(context).pop();
      showMessage(context, 'Location shared with SLG management.');
    } else {
      setState(() {
        _approving = false;
        _error = error;
      });
    }
  }

  Future<void> _decline() async {
    setState(() => _declining = true);
    try {
      await context.read<ApiClient>().post('/location-requests/${widget.request.id}/respond', {'decision': 'decline'});
      widget.onDone();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() {
        _declining = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconDisc(icon: Icons.near_me_rounded, size: 84),
            const SizedBox(height: 18),
            Text('Share your current location?', style: t.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              widget.request.reason ??
                  'SLG management asked for your location. Approving sends one GPS position now. It does not turn on continuous sharing.',
              style: t.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (_error != null) ...[const SizedBox(height: 14), ErrorBanner(message: _error!)],
            const SizedBox(height: 22),
            PrimaryButton(
              label: _approving ? 'Getting GPS fix…' : 'Approve & Share',
              icon: Icons.check_rounded,
              busy: _approving,
              onPressed: _declining ? null : _approve,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: TextButton(
                onPressed: _approving || _declining ? null : _decline,
                child: Text(_declining ? 'Declining…' : 'Decline', style: const TextStyle(color: AppColors.inkSoft, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
