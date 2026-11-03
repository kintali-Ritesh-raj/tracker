import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../ui/theme.dart';
import 'dashboard_screen.dart';
import 'employees_screen.dart';
import 'live_map_screen.dart';
import 'more_screen.dart';
import 'reports_screen.dart';

/// Five-tab admin interface matching the reference bottom navigation.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  /// Pushed routes sit above the shell in the tree, so they reach it by key.
  static final globalKey = GlobalKey<AdminShellState>();

  static AdminShellState of(BuildContext context) => globalKey.currentState!;

  @override
  State<AdminShell> createState() => AdminShellState();
}

class AdminShellState extends State<AdminShell> {
  int _index = 0;
  final _mapKey = GlobalKey<LiveMapScreenState>();

  void select(int index) {
    if (index == _index) return;
    HapticFeedback.selectionClick();
    setState(() => _index = index);
  }

  /// Switches to the map tab, optionally filtered and focused on one employee.
  void openMap({EmployeeStatus? status, int? focusEmployeeId}) {
    select(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapKey.currentState?.apply(status: status, focusEmployeeId: focusEmployeeId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) select(0);
      },
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _index,
          children: [
            const DashboardScreen(),
            LiveMapScreen(key: _mapKey),
            const EmployeesScreen(),
            const ReportsScreen(),
            const MoreScreen(),
          ],
        ),
        bottomNavigationBar: _BottomNav(index: _index, onSelect: select),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    (Icons.home_rounded, Icons.home_outlined, 'Home'),
    (Icons.location_on_rounded, Icons.location_on_outlined, 'Map'),
    (Icons.groups_rounded, Icons.groups_outlined, 'Employees'),
    (Icons.bar_chart_rounded, Icons.bar_chart_outlined, 'Reports'),
    (Icons.menu_rounded, Icons.menu_rounded, 'More'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [BoxShadow(color: Color(0x14C2410C), blurRadius: 24, offset: Offset(0, -4))],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: _NavItem(
                    active: i == index,
                    icon: i == index ? _items[i].$1 : _items[i].$2,
                    label: _items[i].$3,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.active, required this.icon, required this.label, required this.onTap});

  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: active,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            gradient: active ? const LinearGradient(colors: [Color(0xFFFB923C), AppColors.orangeDeep]) : null,
            borderRadius: BorderRadius.circular(16),
            boxShadow: active ? AppShadow.button : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: active ? Colors.white : AppColors.inkSoft),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? Colors.white : AppColors.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
