import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../authentication/presentation/recovery_screen.dart';
import '../../authentication/services/pin_service.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/credential_entry_panel.dart';
import '../services/biometric_status.dart';

/// Blue Lock's own authentication screen, shown by the app-entry gate before
/// the dashboard becomes reachable. Reuses the same PIN panel, error copy and
/// AndroidX system biometric prompt as the protected-app lock screen.
class SelfLockScreen extends StatefulWidget {
  const SelfLockScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SelfLockScreen> createState() => _SelfLockScreenState();
}

class _SelfLockScreenState extends State<SelfLockScreen> {
  final _panelKey = GlobalKey<CredentialEntryPanelState>();
  bool _verifying = false;
  bool _unlocked = false;
  BiometricStatus _biometric = BiometricStatus.unavailable;
  bool _biometricPromptActive = false;
  bool _autoPrompted = false;

  AuthenticationType get _authType => widget.controller.pinService.authType;
  String get _noun => _authType.credentialNoun;

  /// Permanent platform lockout: hide the biometric offer for this mount.
  bool _biometricBlocked = false;

  @override
  void initState() {
    super.initState();
    _initBiometric();
  }

  Future<void> _initBiometric() async {
    final status = await widget.controller.native.getBiometricStatus();
    if (!mounted) return;
    setState(() => _biometric = status);
    // System biometric prompt first when the user enabled it and the device
    // can actually satisfy it. Never before credentials exist: the gate only
    // mounts this screen once a PIN is stored.
    if (status.canUse && !_unlocked) {
      _promptBiometric(auto: true);
    }
  }

  Future<void> _promptBiometric({bool auto = false}) async {
    // At most one system prompt at a time; the automatic attempt runs once
    // per mount so repeated lifecycle rebuilds cannot stack prompts.
    if (_biometricPromptActive || _verifying || _unlocked) return;
    if (auto && _autoPrompted) return;
    if (!_biometric.canUse) return;
    if (auto) _autoPrompted = true;
    setState(() => _biometricPromptActive = true);
    var outcome = 'failed';
    try {
      outcome = await widget.controller.native
          .authenticateBiometricSelf(label: 'Blue Lock');
    } catch (_) {
      // Defensive: an unexpected bridge failure is treated like a failed
      // attempt (PIN keypad stays), never like a pass.
    } finally {
      // Re-arm the button whatever happens, so a lost/late reply can never
      // leave "Unlock with biometrics" permanently disabled.
      _biometricPromptActive = false;
    }
    if (!mounted) return;
    setState(() {}); // rebuild: button enabled again
    if (_unlocked) return;
    if (outcome == 'success') {
      await _grant();
      return;
    }
    if (outcome == 'user_cancel') return; // user chose the PIN keypad
    if (outcome == 'lockout') {
      _panelKey.currentState?.showError(
        'Too many biometric attempts. Use your $_noun or try again shortly.',
      );
      return;
    }
    if (outcome == 'lockout_permanent') {
      if (mounted) setState(() => _biometricBlocked = true);
      _panelKey.currentState?.showError(
        'Biometric unlock is locked. Enter your $_noun. Unlock your device '
        'with its PIN, pattern or password to re-enable it.',
      );
      return;
    }
    // Failure or unavailability: the PIN keypad remains as the fallback.
    await _reportBiometricNotGranted(outcome);
  }

  /// Keeps the error message and the biometric button consistent with each
  /// other: the message is decided by a *fresh* availability check, never by
  /// the raw error code, so "unavailable" can only ever appear together with
  /// the button being hidden (and vice versa).
  Future<void> _reportBiometricNotGranted(String outcome) async {
    final status = await widget.controller.native.getBiometricStatus();
    if (!mounted || _unlocked) return;
    setState(() => _biometric = status);
    _panelKey.currentState?.showError(
      status.canUse
          ? 'Biometric unlock failed. Enter your $_noun.'
          : 'Biometric unlock unavailable. Enter your $_noun.',
    );
  }

  Future<void> _onCredentialCompleted(String credential) async {
    if (_verifying || _unlocked) return;
    setState(() => _verifying = true);
    PinVerification result;
    try {
      result = await widget.controller.pinService
          .verifyPinDetailed(credential);
    } catch (_) {
      if (!mounted) return;
      setState(() => _verifying = false);
      _panelKey.currentState
          ?.showError('Could not verify your $_noun. Try again.');
      return;
    }
    if (!mounted) return;
    setState(() => _verifying = false);
    if (result.isSuccess) {
      await _grant();
    } else {
      _panelKey.currentState?.showError(result.message);
    }
  }

  /// Successful biometrics OR a valid PIN open the app - never both. The
  /// gate watches the controller and swaps the dashboard in; no navigation
  /// happens here so nothing can bounce back to the splash screen.
  Future<void> _grant() async {
    if (_unlocked) return;
    _unlocked = true;
    await widget.controller.grantSelfSession();
  }

  /// Opens the verified recovery flow. Cancelling or failing verification
  /// leaves the current lock, protected apps and settings untouched.
  Future<void> _forgotPin() async {
    if (_verifying || _unlocked) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecoveryScreen(
          controller: widget.controller,
          biometricAvailable:
              _biometric.available && _biometric.enrolled,
          requestBiometric: () => widget.controller.native
              .authenticateBiometricSelf(label: 'Blue Lock'),
        ),
      ),
    );
    if (!mounted) return;
    _panelKey.currentState?.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AppLogo(size: 76),
                const SizedBox(height: 14),
                const Text(
                  'Blue Lock',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
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
                CredentialEntryPanel(
                  key: _panelKey,
                  type: _authType,
                  heading: 'App Locked',
                  description: _authType.verifyDescription,
                  actionLabel: _verifying ? 'Checking...' : 'Unlock',
                  onCompleted: _onCredentialCompleted,
                  forgotLabel: _authType.forgotLabel,
                  onForgot: _forgotPin,
                ),
                if (_biometric.canUse && !_biometricBlocked)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton.icon(
                      onPressed: _biometricPromptActive
                          ? null
                          : () => _promptBiometric(),
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
