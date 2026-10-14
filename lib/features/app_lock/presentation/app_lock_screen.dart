import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../installed_apps/models/installed_app.dart';
import '../../installed_apps/services/apps_repository.dart';
import '../services/biometric_status.dart';
import '../services/lock_session.dart';
import '../../../core/utils/perf_log.dart';
import '../../../shared/widgets/pin_entry_panel.dart';

/// Screen G: authentication screen shown when a protected app is opened.
/// Displays the target app's icon/name, PIN indicators and keypad. No bottom
/// navigation here - this is not the dashboard.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({
    super.key,
    required this.packageName,
    required this.controller,
    this.onUnlocked,
    this.nativeLock = false,
  });

  final String packageName;
  final AppController controller;

  /// Called after a successful unlock (when shown in-app as a preview).
  final VoidCallback? onUnlocked;

  /// True when rendered by the native LockActivity over a protected app.
  /// Only then may the system biometric prompt be auto-launched and the
  /// forgot-PIN reset relies on the native activity finishing itself.
  final bool nativeLock;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _panelKey = GlobalKey<PinEntryPanelState>();
  InstalledApp? _app;
  bool _verifying = false;
  bool _unlocked = false;
  BiometricStatus _biometric = BiometricStatus.unavailable;
  bool _biometricPromptActive = false;

  @override
  void initState() {
    super.initState();
    PerfLog.mark('lock: initState for ${widget.packageName}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PerfLog.mark('lock: first frame rendered (PIN usable)');
      LockSession.markUsable();
    });
    _loadApp();
    _initBiometric();
  }

  Future<void> _loadApp() async {
    var app = widget.controller.findApp(widget.packageName);
    if (app == null) {
      try {
        app = await AppsRepository(widget.controller.native)
            .getAppInfo(widget.packageName);
      } catch (_) {
        app = null;
      }
    }
    if (!mounted) return;
    setState(() => _app = app);
  }

  Future<void> _initBiometric() async {
    final status = await LockSession.biometricStatus();
    if (!mounted) return;
    setState(() => _biometric = status);
    // Only the native lock screen (over a protected app) auto-launches the
    // system prompt; the in-app preview just offers the button.
    if (widget.nativeLock && status.canUse && !_unlocked) {
      _promptBiometric();
    }
  }

  Future<void> _promptBiometric() async {
    if (_biometricPromptActive || _verifying || _unlocked) return;
    if (!_biometric.canUse) return;
    _biometricPromptActive = true;
    final outcome = await LockSession.authenticateBiometric(
      packageName: widget.packageName,
      label: _app?.label ?? widget.packageName,
    );
    _biometricPromptActive = false;
    if (!mounted || _unlocked) return;
    if (outcome == 'success') {
      _unlocked = true;
      await LockSession.unlock(widget.packageName);
      widget.onUnlocked?.call();
      // Native LockActivity dismisses itself; in-app preview pops back.
      if (mounted && widget.onUnlocked != null) {
        Navigator.of(context).maybePop();
      }
      return;
    }
    if (outcome == 'user_cancel') return; // user chose the PIN keypad
    // Failure or unavailability: PIN keypad remains as the fallback.
    _panelKey.currentState?.showError(
      outcome == 'unavailable'
          ? 'Biometric unlock unavailable. Enter your PIN.'
          : 'Biometric unlock failed. Enter your PIN.',
    );
  }

  Future<void> _onPinCompleted(String pin) async {
    if (_verifying || _unlocked) return;
    setState(() => _verifying = true);
    final ok = await widget.controller.pinService.verifyPin(pin);
    if (!mounted) return;
    setState(() => _verifying = false);
    if (ok) {
      _unlocked = true;
      await LockSession.unlock(widget.packageName);
      widget.onUnlocked?.call();
      // When running inside the native LockActivity, native dismisses us.
      // In-app preview: pop back.
      if (mounted && widget.onUnlocked != null) {
        Navigator.of(context).maybePop();
      }
    } else {
      _panelKey.currentState?.showError('Incorrect PIN. Try again.');
    }
  }

  Future<void> _forgotPin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Forgot PIN?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: const Text(
          'Your PIN cannot be recovered. Resetting Blue Lock removes your '
          'PIN and unprotects all apps so you can set up a new PIN.',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset Blue Lock',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.controller.resetProtection();
      await LockSession.resetProtection();
      if (widget.nativeLock) {
        // Native LockActivity wipes prefs and finishes itself; do not
        // navigate the lock engine to any Blue Lock screen.
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/onboarding', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final name = app?.label ?? widget.packageName;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: AppColors.lavender,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: app?.iconBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image.memory(
                            app!.iconBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                        )
                      : const Icon(Icons.apps_rounded,
                          size: 34, color: AppColors.primary),
                ),
                const SizedBox(height: 14),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.lock_rounded,
                      size: 26, color: Colors.white),
                ),
                const SizedBox(height: 18),
                PinEntryPanel(
                  key: _panelKey,
                  heading: 'App Locked',
                  description: 'Enter your PIN to continue.',
                  actionLabel: _verifying ? 'Checking...' : 'Unlock',
                  onCompleted: _onPinCompleted,
                  forgotLabel: 'Forgot PIN?',
                  onForgot: _forgotPin,
                ),
                if (_biometric.canUse)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton.icon(
                      onPressed:
                          _biometricPromptActive ? null : _promptBiometric,
                      icon: const Icon(
                        Icons.fingerprint_rounded,
                        size: 22,
                        color: AppColors.primary,
                      ),
                      label: const Text(
                        'Unlock with biometrics',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
