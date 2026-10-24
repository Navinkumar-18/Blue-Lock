import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../authentication/presentation/recovery_screen.dart';
import '../../authentication/services/pin_service.dart';
import '../../installed_apps/models/installed_app.dart';
import '../../installed_apps/services/apps_repository.dart';
import '../services/biometric_status.dart';
import '../services/lock_session.dart';
import '../../../core/utils/perf_log.dart';
import '../../../shared/widgets/credential_entry_panel.dart';

/// Screen G: authentication screen shown when a protected app is opened.
/// Displays the target app's icon/name, PIN indicators and keypad. No bottom
/// navigation here - this is not the dashboard.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({
    super.key,
    required this.packageName,
    required this.controller,
    this.chatUsername,
    this.onUnlocked,
    this.nativeLock = false,
  });

  final String packageName;
  final AppController controller;

  /// When non-null, this screen guards one Instagram conversation instead of
  /// the whole app. The value is a normalised username, never a display name.
  final String? chatUsername;

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
  final _panelKey = GlobalKey<CredentialEntryPanelState>();
  InstalledApp? _app;
  bool _verifying = false;
  bool _unlocked = false;
  BiometricStatus _biometric = BiometricStatus.unavailable;
  bool _biometricPromptActive = false;

  AuthenticationType get _authType => widget.controller.pinService.authType;
  String get _noun => _authType.credentialNoun;
  bool get _isChatLock =>
      widget.chatUsername != null && widget.chatUsername!.isNotEmpty;
  String get _targetLabel => _isChatLock
      ? '@${widget.chatUsername}'
      : (_app?.label ?? widget.packageName);

  /// Set after the platform reports a permanent biometric lockout: the
  /// biometric button would only fail until the device is unlocked with its
  /// primary credential, so it is hidden for this lock session.
  bool _biometricBlocked = false;

  /// The automatic prompt runs at most once per mount: repeated attempts are
  /// always user-initiated, so a failing prompt can never loop on its own.
  bool _autoPrompted = false;

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
    PerfLog.mark('lock: biometric status canUse=${status.canUse}');
    setState(() => _biometric = status);
    // Only the native lock screen (over a protected app) auto-launches the
    // system prompt; the in-app preview just offers the button.
    if (widget.nativeLock && status.canUse && !_unlocked) {
      _promptBiometric(auto: true);
    }
  }

  Future<void> _promptBiometric({bool auto = false}) async {
    if (_biometricPromptActive || _verifying || _unlocked) return;
    if (auto && _autoPrompted) return;
    if (!_biometric.canUse) return;
    if (auto) _autoPrompted = true;
    PerfLog.mark('lock: biometric prompt requested (auto=$auto)');
    setState(() => _biometricPromptActive = true);
    var outcome = 'failed';
    try {
      outcome = await LockSession.authenticateBiometric(
        packageName: widget.packageName,
        label: _targetLabel,
      );
    } catch (_) {
      // Defensive: an unexpected bridge failure is treated like a failed
      // attempt (PIN keypad stays), never like a pass.
    } finally {
      // Re-arm the button whatever happens, so a lost/late reply can never
      // leave "Unlock with biometrics" permanently disabled.
      _biometricPromptActive = false;
    }
    if (!mounted || _unlocked) return;
    setState(() {}); // rebuild: button enabled again
    PerfLog.mark('lock: biometric outcome=$outcome');
    if (outcome == 'success') {
      _unlocked = true;
      await _recordUnlock();
      widget.onUnlocked?.call();
      // Native LockActivity dismisses itself; in-app preview pops back.
      if (mounted && widget.onUnlocked != null) {
        Navigator.of(context).maybePop();
      }
      return;
    }
    if (outcome == 'user_cancel') return; // user chose the PIN keypad
    if (outcome == 'lockout') {
      // Temporary platform lockout: biometrics stay offered (they recover on
      // their own), but the user needs an accurate explanation now.
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
    // Failure or unavailability: PIN keypad remains as the fallback.
    await _reportBiometricNotGranted(outcome);
  }

  /// Keeps the error message and the biometric button consistent with each
  /// other. The message is decided by a *fresh* availability check, never by
  /// the raw error code: "unavailable" is only shown when biometrics really
  /// cannot be used (and the button below disappears with it), while a
  /// transient refusal - prompt already busy, host not ready - keeps the
  /// button offered and reads as a failed attempt.
  Future<void> _reportBiometricNotGranted(String outcome) async {
    final status = await LockSession.biometricStatus();
    if (!mounted || _unlocked) return;
    PerfLog.mark(
      'lock: biometric not granted outcome=$outcome canUse=${status.canUse}',
    );
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
      // Storage/crypto failure - never report it as an incorrect credential.
      if (!mounted) return;
      setState(() => _verifying = false);
      _panelKey.currentState
          ?.showError('Could not verify your $_noun. Try again.');
      return;
    }
    if (!mounted) return;
    setState(() => _verifying = false);
    if (result.isSuccess) {
      _unlocked = true;
      await _recordUnlock();
      widget.onUnlocked?.call();
      // When running inside the native LockActivity, native dismisses us.
      // In-app preview: pop back.
      if (mounted && widget.onUnlocked != null) {
        Navigator.of(context).maybePop();
      }
    } else {
      _panelKey.currentState?.showError(result.message);
    }
  }

  /// Records the successful authentication with the existing native session
  /// primitives: a conversation session for chat lock, the app session
  /// otherwise. Never called when verification failed or was cancelled.
  Future<void> _recordUnlock() async {
    final chat = widget.chatUsername;
    if (chat != null && chat.isNotEmpty) {
      await LockSession.unlockChat(
        packageName: widget.packageName,
        username: chat,
      );
    } else {
      await LockSession.unlock(widget.packageName);
    }
  }

  /// Opens the verified recovery flow. Nothing is cleared here: the lock and
  /// the protected-app list stay intact unless recovery succeeds and the user
  /// configures a new credential.
  Future<void> _forgotPin() async {
    if (_verifying || _unlocked) return;
    final label = _targetLabel;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecoveryScreen(
          controller: widget.controller,
          biometricAvailable:
              _biometric.available && _biometric.enrolled,
          requestBiometric: widget.nativeLock
              ? () => LockSession.authenticateBiometric(
                    packageName: widget.packageName,
                    label: label,
                  )
              : null,
          nativeLock: widget.nativeLock,
        ),
      ),
    );
    if (!mounted) return;
    // A verified recovery may have replaced the credential and type. Rebuild
    // so this still-mounted lock screen reflects the new method; the user
    // then proves the new credential by unlocking normally.
    _panelKey.currentState?.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final name = _targetLabel;
    final heading = _isChatLock ? 'Conversation Locked' : 'App Locked';
    final description = _isChatLock
        ? 'This Instagram conversation is protected. '
            '${_authType.verifyDescription}'
        : _authType.verifyDescription;
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
                    color: AppColors.paleBlueSoft,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: app?.iconBytes != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Image(
                            // Decode at on-screen size (76 logical px).
                            image: ResizeImage(
                              MemoryImage(app!.iconBytes!),
                              width: (76 *
                                      MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                            ),
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
                CredentialEntryPanel(
                  key: _panelKey,
                  type: _authType,
                  heading: heading,
                  description: description,
                  actionLabel: _verifying ? 'Checking...' : 'Unlock',
                  onCompleted: _onCredentialCompleted,
                  forgotLabel: _authType.forgotLabel,
                  onForgot: _forgotPin,
                ),
                if (_biometric.canUse && !_biometricBlocked)
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
