import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../permissions/presentation/permissions_screen.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';

/// Screen E: home dashboard - branding, greeting, protected-app summary,
/// protection status and setup guidance. All values come from real state.
class HomeDashboard extends StatefulWidget {
  const HomeDashboard({
    super.key,
    required this.controller,
    required this.onManageApps,
    required this.onOpenSettings,
  });

  final AppController controller;
  final VoidCallback onManageApps;
  final VoidCallback onOpenSettings;

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.refreshPermissions();
      widget.controller.loadInstalledApps();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.refreshPermissions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return RefreshIndicator(
              onRefresh: () async {
                await controller.refreshPermissions();
                await controller.loadInstalledApps(force: true);
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(context, controller),
                    const SizedBox(height: 20),
                    const Text(
                      'Your privacy',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Choose which apps require your PIN to open.',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (controller.protectedCount == 0)
                      _emptyState(controller)
                    else
                      _summaryCard(controller),
                    const SizedBox(height: 22),
                    const SectionTitle('Protection Status'),
                    _statusCard(controller),
                    if (!controller.permissionsGranted) ...[
                      const SizedBox(height: 14),
                      _setupBanner(controller),
                    ],
                    const SizedBox(height: 14),
                    _tipCard(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppController controller) {
    return Row(
      children: [
        const AppLogo(size: 36),
        const SizedBox(width: 10),
        const Text(
          'Blue Lock',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const Spacer(),
        IconButton(
          onPressed: widget.onOpenSettings,
          icon: const Icon(Icons.settings_outlined,
              color: AppColors.textSecondary),
          tooltip: 'Settings',
        ),
      ],
    );
  }

  Widget _emptyState(AppController controller) {
    return BlueLockCard(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.paleBlueSoft,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.lock_outline,
                size: 30, color: AppColors.primary),
          ),
          const SizedBox(height: 14),
          const Text(
            'No apps protected yet',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Select the apps you want to lock. Blue Lock will ask for your '
            'PIN whenever they are opened.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: 'Choose apps',
            icon: Icons.apps_outlined,
            onPressed: widget.onManageApps,
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(AppController controller) {
    return BlueLockCard(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.paleBlueSoft,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.shield_outlined,
                    size: 24, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${controller.protectedCount} '
                      '${controller.protectedCount == 1 ? 'app' : 'apps'} protected',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Locked apps require your PIN to open.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Manage Protected Apps',
            icon: Icons.apps_outlined,
            onPressed: widget.onManageApps,
          ),
        ],
      ),
    );
  }

  Widget _statusCard(AppController controller) {
    return BlueLockCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          _statusRow(
            icon: Icons.pin_outlined,
            title: 'PIN configured',
            subtitle: controller.hasPin
                ? 'Your privacy PIN is active'
                : 'Create a PIN to protect apps',
            pill: StatusPill(
              label: controller.hasPin ? 'Active' : 'Required',
              tone: controller.hasPin
                  ? StatusTone.success
                  : StatusTone.warning,
            ),
            onTap: controller.hasPin
                ? null
                : () => Navigator.of(context).pushNamed('/create-pin'),
          ),
          const Divider(),
          _statusRow(
            icon: Icons.access_time_outlined,
            title: 'Usage Access',
            subtitle: controller.usageAccess
                ? 'Blue Lock can detect open apps'
                : 'Required to detect protected apps',
            pill: StatusPill(
              label: controller.usageAccess ? 'Granted' : 'Missing',
              tone: controller.usageAccess
                  ? StatusTone.success
                  : StatusTone.danger,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PermissionsScreen(controller: controller),
              ),
            ),
          ),
          const Divider(),
          _statusRow(
            icon: Icons.layers_outlined,
            title: 'Display Over Other Apps',
            subtitle: controller.overlayPermission
                ? 'Lock screen can appear over apps'
                : 'Optional for the lock screen',
            pill: StatusPill(
              label: controller.overlayPermission
                  ? 'Granted'
                  : (controller.native.available ? 'Optional' : 'Missing'),
              tone: controller.overlayPermission
                  ? StatusTone.success
                  : StatusTone.neutral,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PermissionsScreen(controller: controller),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required StatusPill pill,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            pill,
            if (onTap != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right,
                  size: 20, color: AppColors.textSecondary),
            ],
          ],
        ),
      ),
    );
  }

  Widget _setupBanner(AppController controller) {
    return BlueLockCard(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.warningBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.error_outline,
                size: 20, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Grant Usage Access so Blue Lock can protect your apps.',
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PermissionsScreen(controller: controller),
              ),
            ),
            icon: const Icon(Icons.chevron_right, color: AppColors.primary),
          ),
        ],
      ),
    );
  }

  Widget _tipCard() {
    return BlueLockCard(
      child: Row(
        children: [
          const Icon(Icons.lightbulb_outline,
              size: 20, color: AppColors.accent),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Tip: Lock messaging and banking apps for extra privacy.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
