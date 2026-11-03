import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../../core/session.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final session = context.read<Session>();
    final unpair = context.read<VoidCallback>();
    return Scaffold(
      body: AppBackground(
        skyline: true,
        child: SafeArea(
          child: Column(
            children: [
              const BackHeader(title: 'About'),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    const Center(child: SlgLogo(height: 64)),
                    const SizedBox(height: 18),
                    Center(
                      child: FutureBuilder<PackageInfo>(
                        future: PackageInfo.fromPlatform(),
                        builder: (_, snap) => Text(
                          'SLG FieldTrack ${snap.data == null ? '' : 'v${snap.data!.version} (${snap.data!.buildNumber})'}',
                          style: t.titleSmall,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Privacy', style: t.titleSmall),
                          const SizedBox(height: 6),
                          Text(
                            'Locations come only from employees who turned on sharing in their own app, or who approved a '
                            'specific request. Employees can pause sharing at any time. Positions are never estimated or filled in.',
                            style: t.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Support', style: t.titleSmall),
                          const SizedBox(height: 6),
                          Text('Server: ${session.serverUrl}', style: t.bodyMedium),
                          const SizedBox(height: 4),
                          Text(
                            'For pairing or access problems, contact your SLG FieldTrack server administrator. '
                            'If an admin phone is lost, revoke it under More → Paired Devices from another admin phone.',
                            style: t.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Unpair this phone?'),
                            content: const Text('You will need a new pairing code to use this phone again.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Unpair')),
                            ],
                          ),
                        );
                        if (ok == true) unpair();
                      },
                      icon: const Icon(Icons.logout_rounded, color: AppColors.offline),
                      label: const Text('Unpair this phone', style: TextStyle(color: AppColors.offline)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
