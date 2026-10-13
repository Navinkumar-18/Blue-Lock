import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';

/// Screen H: permission setup checklist with real OS permission state.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    setState(() => _checking = true);
    await widget.controller.refreshPermissions();
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _openUsageAccess() async {
    await widget.controller.permissions.openUsageAccessSettings();
  }

  Future<void> _openOverlay() async {
    await widget.controller.permissions.openOverlaySettings();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Permissions'),
        leading: const BackButton(color: AppColors.textPrimary),
        actions: [
          IconButton(
            onPressed: _checking ? null : _refresh,
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'Re-check',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Blue Lock needs these permissions to protect your apps. '
                  'Status is read directly from Android settings.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),
                PermissionRow(
                  title: 'Usage Access',
                  description:
                      'Lets Blue Lock detect which app is in the foreground '
                      'so it can show the lock screen.',
                  granted: controller.usageAccess,
                  grantedLabel: 'Granted',
                  missingLabel: 'Required',
                  missingTone: StatusTone.danger,
                  actionLabel: controller.usageAccess
                      ? 'Open settings'
                      : 'Grant access',
                  onAction: _openUsageAccess,
                ),
                const SizedBox(height: 14),
                PermissionRow(
                  title: 'Display Over Other Apps',
                  description:
                      'Not required for Blue Lock\u2019s lock screen. Shown for '
                      'reference on devices where overlays are used.',
                  granted: controller.overlayPermission,
                  grantedLabel: 'Granted',
                  missingLabel: 'Not required',
                  missingTone: StatusTone.neutral,
                  actionLabel: 'Open settings',
                  onAction: _openOverlay,
                ),
                const SizedBox(height: 22),
                PrimaryButton(
                  label: _checking ? 'Checking...' : 'Re-check permissions',
                  onPressed: _checking ? null : _refresh,
                  icon: Icons.sync,
                ),
                if (!controller.usageAccess) ...[
                  const SizedBox(height: 14),
                  BlueLockCard(
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 20, color: AppColors.warning),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'After granting Usage Access, return to Blue Lock '
                            'and pull to refresh.',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Row with permission name, explanation, live status pill and settings
/// action.
class PermissionRow extends StatelessWidget {
  const PermissionRow({
    super.key,
    required this.title,
    required this.description,
    required this.granted,
    required this.grantedLabel,
    required this.missingLabel,
    required this.missingTone,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String description;
  final bool granted;
  final String grantedLabel;
  final String missingLabel;
  final StatusTone missingTone;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return BlueLockCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              StatusPill(
                label: granted ? grantedLabel : missingLabel,
                tone: granted ? StatusTone.success : missingTone,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: OutlinedButton(
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                textStyle:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              child: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}
