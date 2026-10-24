import 'package:flutter/material.dart';

import '../../app_lock/presentation/app_lock_screen.dart';
import '../../authentication/presentation/change_lock_type_screen.dart';
import '../../authentication/presentation/change_pin_screen.dart';
import '../../authentication/presentation/recovery_code_setup_screen.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../permissions/presentation/permissions_screen.dart';
import '../../../shared/widgets/cards.dart';

/// Screen I: security settings - protection toggle, change PIN, relock
/// policy, permission status and app info.
///
/// Rebuild scoping: only the sections whose values come from the controller
/// listen to it ([_ProtectionSection], [_RelockSection],
/// [_PermissionsSection]). A permission refresh or app-count notification
/// from elsewhere in the app no longer rebuilds the header, Security card
/// or About card.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Settings',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 18),
              const SectionTitle('Protection'),
              _ProtectionSection(controller: controller),
              const SizedBox(height: 18),
              const SectionTitle('Security'),
              _securityCard(context),
              const SizedBox(height: 18),
              const SectionTitle('Automatic relock'),
              _RelockSection(controller: controller),
              const SizedBox(height: 18),
              const SectionTitle('Permissions'),
              _PermissionsSection(controller: controller),
              const SizedBox(height: 18),
              const SectionTitle('About'),
              _AboutSection(controller: controller),
            ],
          ),
        ),
      ),
    );
  }

  Widget _securityCard(BuildContext context) {
    final type = controller.authType;
    final credentialTitle = type.isPin
        ? 'Change PIN'
        : type.isPattern
            ? 'Change pattern'
            : 'Change password';
    return BlueLockCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.pin_outlined, color: AppColors.primary),
            title: Text(
              credentialTitle,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            subtitle: Text(
              'Verify your current ${type.credentialNoun} to set a new one',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChangePinScreen(
                    pinService: controller.pinService,
                  ),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.swap_horiz_rounded,
                color: AppColors.primary),
            title: const Text(
              'Change Lock Type',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            subtitle: Text(
              'Currently ${type.title}. Switch to a PIN, pattern or password',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChangeLockTypeScreen(controller: controller),
                ),
              );
            },
          ),
          const Divider(),
          _ChatLockTile(controller: controller),
          const Divider(),
          _RecoveryTile(controller: controller),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.refresh_outlined,
                color: AppColors.primary),
            title: const Text(
              'Preview lock screen',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            subtitle: const Text(
              'See what a locked app looks like',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
            onTap: () {
              final sample = controller.installedApps
                  .where((a) => controller.isLocked(a.packageName))
                  .toList();
              final packageName = sample.isNotEmpty
                  ? sample.first.packageName
                  : 'com.bluelock.app';
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AppLockScreen(
                    packageName: packageName,
                    controller: controller,
                    onUnlocked: () {},
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

}

/// Entry point for the experimental Instagram Chat Lock. The route is wrapped
/// in [SelfAuthGate] by the app router, so opening the management screen (and
/// therefore viewing or removing protected conversations) requires the same
/// Blue Lock credential as the rest of the app.
class _ChatLockTile extends StatelessWidget {
  const _ChatLockTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final enabled = controller.chatLockEnabled;
        final count = controller.protectedChats.length;
        final subtitle = !enabled
            ? 'Experimental - off'
            : count == 0
                ? 'On - no conversations protected yet'
                : 'On - $count conversation${count == 1 ? '' : 's'} protected';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.chat_bubble_outline_rounded,
              color: AppColors.primary),
          title: const Text(
            'Instagram Chat Lock',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusPill(
                label: enabled ? 'On' : 'Off',
                tone: enabled ? StatusTone.success : StatusTone.neutral,
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
          onTap: () => Navigator.of(context).pushNamed('/chat-lock'),
        );
      },
    );
  }
}

/// Recovery-code entry point. Existing installations see "Set up" here (a
/// recovery code is never silently created for a user who never received
/// one); new installations already generated it during onboarding.
class _RecoveryTile extends StatefulWidget {
  const _RecoveryTile({required this.controller});

  final AppController controller;

  @override
  State<_RecoveryTile> createState() => _RecoveryTileState();
}

class _RecoveryTileState extends State<_RecoveryTile> {
  bool? _configured;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    bool configured = false;
    try {
      configured =
          await widget.controller.recoveryService.hasRecoveryCode();
    } catch (_) {
      configured = false;
    }
    if (!mounted) return;
    setState(() {
      _configured = configured;
      _loading = false;
    });
  }

  Future<void> _open() async {
    if (_loading) return;
    if (_configured == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Generate a new recovery code?',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: const Text(
            'The new code is shown once. Your existing recovery code stops '
            'working as soon as the new one is saved.',
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Generate'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            RecoveryCodeSetupScreen(controller: widget.controller),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final configured = _configured;
    final subtitle = _loading
        ? 'Checking secure storage...'
        : configured == true
            ? 'Configured - use it if you forget your lock'
            : 'Not set up - add a way back into Blue Lock';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.key_rounded, color: AppColors.primary),
      title: const Text(
        'Recovery code',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_loading)
            StatusPill(
              label: configured == true ? 'Ready' : 'Not set',
              tone: configured == true
                  ? StatusTone.success
                  : StatusTone.warning,
            ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        ],
      ),
      onTap: _open,
    );
  }
}

/// About card: shows the version actually installed on the device instead of
/// a hardcoded string. Falls back to "unavailable" on platforms without the
/// native bridge (tests/desktop).
class _AboutSection extends StatefulWidget {
  const _AboutSection({required this.controller});

  final AppController controller;

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final version = await widget.controller.native.getAppVersion();
    if (mounted) setState(() => _version = version);
  }

  @override
  Widget build(BuildContext context) {
    return BlueLockCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Blue Lock',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _version == null ? 'Version unavailable' : 'Version $_version',
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Your PIN, pattern or password never leaves this device. Blue '
            'Lock stores only salted verifiers. Recovery codes are stored as '
            'verifiers too, never as plain text, and no data is uploaded.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Protection card (app-lock master switch + biometric switch): rebuilds
/// alone when either switch or the biometric status changes.
class _ProtectionSection extends StatelessWidget {
  const _ProtectionSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return BlueLockCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              SwitchListTile(
                value: controller.lockEnabled,
                onChanged: controller.setLockEnabled,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'App-lock protection',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  controller.lockEnabled
                      ? 'Protected apps require your '
                          '${controller.authType.credentialNoun}'
                      : 'All apps are currently unlocked',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              SwitchListTile(
                value: controller.biometricEnabled,
                onChanged: controller.biometricUsable ||
                        (controller.biometric.available &&
                            controller.biometric.enrolled)
                    ? controller.setBiometricEnabled
                    : null,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Biometric unlock',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  !controller.biometric.available
                      ? 'Not available on this device'
                      : controller.biometricEnabled
                          ? 'Fingerprint can unlock protected apps'
                          : 'PIN required for every unlock',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Automatic-relock options: rebuilds alone when the selection changes.
class _RelockSection extends StatelessWidget {
  const _RelockSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return BlueLockCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: RelockOption.values.map((option) {
              final selected =
                  controller.relockTimeoutSeconds == option.seconds;
              return InkWell(
                onTap: () => controller.setRelockTimeout(option.seconds),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color:
                            selected ? AppColors.primary : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          option.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

/// Permissions card: rebuilds alone when permission state refreshes.
class _PermissionsSection extends StatelessWidget {
  const _PermissionsSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return BlueLockCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Usage Access',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusPill(
                      label: controller.usageAccess ? 'Granted' : 'Missing',
                      tone: controller.usageAccess
                          ? StatusTone.success
                          : StatusTone.danger,
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right,
                        size: 20, color: AppColors.textSecondary),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PermissionsScreen(controller: controller),
                  ),
                ),
              ),
              const Divider(),
              if (controller.permissions.batteryGuidanceRelevant)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Battery & Background',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusPill(
                        label: controller.batteryOptimizationIgnored &&
                                controller.notificationPermission
                            ? 'Ready'
                            : 'Review',
                        tone: controller.batteryOptimizationIgnored &&
                                controller.notificationPermission
                            ? StatusTone.success
                            : StatusTone.warning,
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right,
                          size: 20, color: AppColors.textSecondary),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PermissionsScreen(controller: controller),
                    ),
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Display Over Other Apps',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusPill(
                      label: controller.overlayPermission
                          ? 'Granted'
                          : 'Not required',
                      tone: controller.overlayPermission
                          ? StatusTone.success
                          : StatusTone.neutral,
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right,
                        size: 20, color: AppColors.textSecondary),
                  ],
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
      },
    );
  }
}
