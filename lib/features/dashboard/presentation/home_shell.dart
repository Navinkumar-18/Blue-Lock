import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/perf_log.dart';
import '../../installed_apps/presentation/manage_apps_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import 'home_dashboard.dart';

/// Bottom navigation shell with Home / Apps / Settings destinations.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Timing mark for setup-flow measurements (debug builds only).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PerfLog.mark('home: first frame');
    });
  }

  void goToTab(int index) {
    if (index != _index) {
      PerfLog.phase(switch (index) {
        1 => 'apps-tab',
        2 => 'settings-tab',
        _ => 'home-tab',
      });
    }
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeDashboard(
            controller: widget.controller,
            onManageApps: () => goToTab(1),
            onOpenSettings: () => goToTab(2),
          ),
          ManageAppsScreen(controller: widget.controller),
          SettingsScreen(controller: widget.controller),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: goToTab,
          backgroundColor: AppColors.surface,
          surfaceTintColor: Colors.transparent,
          height: 66,
          indicatorColor: AppColors.paleBlue,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded, color: AppColors.primary),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.apps_outlined),
              selectedIcon: Icon(Icons.apps_rounded, color: AppColors.primary),
              label: 'Apps',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon:
                  Icon(Icons.settings_rounded, color: AppColors.primary),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
