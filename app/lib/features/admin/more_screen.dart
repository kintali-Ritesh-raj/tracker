import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_shell.dart';
import 'manage/about_screen.dart';
import 'manage/app_settings_screen.dart';
import 'manage/devices_screen.dart';
import 'manage/manage_employees_screen.dart';
import 'manage/permissions_overview_screen.dart';
import 'manage/sites_screen.dart';
import 'manage/teams_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    final items = [
      (Icons.groups_rounded, 'Manage Employees', 'Add, Edit, Remove', () => open(const ManageEmployeesScreen())),
      (Icons.diversity_3_rounded, 'Manage Teams', 'Create & Assign Teams', () => open(const TeamsScreen())),
      (Icons.location_on_rounded, 'Sites / Locations', 'Manage service locations', () => open(const SitesScreen())),
      (Icons.bar_chart_rounded, 'Reports', 'Attendance, Location, Site Visits', () => AdminShell.of(context).select(3)),
      (Icons.settings_rounded, 'App Settings', 'Map, Permissions, Notifications', () => open(const AppSettingsScreen())),
      (Icons.verified_user_rounded, 'Location Permissions', 'Consent and phone health per employee', () => open(const PermissionsOverviewScreen())),
      (Icons.devices_rounded, 'Paired Devices', 'Admin phones, revoke access', () => open(const DevicesScreen())),
      (Icons.info_outline_rounded, 'About', 'App version, Support', () => open(const AboutScreen())),
    ];
    return AppBackground(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            BackHeader(title: 'More', onBack: () => AdminShell.of(context).select(0)),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final (icon, title, subtitle, onTap) = items[i];
                  return MenuCard(icon: icon, title: title, subtitle: subtitle, onTap: onTap);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MenuCard extends StatelessWidget {
  const MenuCard({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      radius: AppRadius.tile,
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, color: AppColors.orange, size: 30),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 13.5, color: AppColors.inkSoft)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.ink),
        ],
      ),
    );
  }
}
