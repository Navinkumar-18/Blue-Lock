import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/authentication/recovery_code.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';
import '../../../shared/widgets/credential_setup_panel.dart';
import '../services/recovery_service.dart';
import 'choose_lock_type_screen.dart';
import 'recovery_code_setup_screen.dart';

/// Verified recovery for a forgotten lock.
///
/// Opening this screen never clears the credential or the protected-app list.
/// The existing lock is only replaced after the user proves a recovery factor
/// (enrolled biometrics or the recovery code) *and* configures and
/// confirms a new credential. Cancelling at any step leaves everything as it
/// was.
class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({
    super.key,
    required this.controller,
    this.biometricAvailable = false,
    this.requestBiometric,
    this.nativeLock = false,
  });

  final AppController controller;

  /// True when the platform reports hardware + an enrolled biometric. The
  /// user preference for everyday unlock is deliberately not required here:
  /// recovery is an explicit, user-chosen action.
  final bool biometricAvailable;

  /// Launches the platform biometric prompt through the correct channel
  /// (lock channel inside LockActivity, native channel in the dashboard).
  /// Returns the shared outcome vocabulary ('success', 'user_cancel',
  /// 'lockout', 'lockout_permanent', 'unavailable', 'failed').
  final Future<String> Function()? requestBiometric;

  /// True when hosted over a protected app. Only affects copy, never trust.
  final bool nativeLock;

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

enum _RecoveryStep { options, code, chooseType, configure }

class _RecoveryScreenState extends State<RecoveryScreen> {
  final TextEditingController _codeController = TextEditingController();
  final FocusNode _codeFocus = FocusNode();

  _RecoveryStep _step = _RecoveryStep.options;
  bool _loadingFactors = true;
  bool _hasRecoveryCode = false;
  bool _factorsReadFailed = false;
  bool _biometricAvailable = false;
  bool _busy = false;
  String? _error;
  bool _obscureCode = true;
  AuthenticationType? _newType;

  @override
  void initState() {
    super.initState();
    _biometricAvailable = widget.biometricAvailable;
    _loadFactors();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// Reads whether a recovery code exists. This is a read-only check: a
  /// missing/failed read must never alter the current credential.
  Future<void> _loadFactors() async {
    var hasCode = false;
    var failed = false;
    try {
      hasCode = await widget.controller.recoveryService.hasRecoveryCode();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _hasRecoveryCode = hasCode;
      _factorsReadFailed = failed;
      _loadingFactors = false;
    });
  }

  Future<void> _useBiometric() async {
    final request = widget.requestBiometric;
    if (request == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var outcome = 'failed';
    try {
      outcome = await request();
    } catch (_) {
      outcome = 'failed';
    }
    if (!mounted) return;
    switch (outcome) {
      case 'success':
        setState(() {
          _busy = false;
          _error = null;
          _step = _RecoveryStep.chooseType;
        });
      case 'user_cancel':
        setState(() => _busy = false);
      case 'lockout':
        setState(() {
          _busy = false;
          _error =
              'Too many biometric attempts. '
              '${_hasRecoveryCode ? 'Use your recovery code or try again shortly.' : 'Try again shortly.'}';
        });
      case 'lockout_permanent':
        setState(() {
          _busy = false;
          _biometricAvailable = false;
          _error =
              'Biometric recovery is locked. Unlock your device with '
              'its own PIN, pattern or password to re-enable it.';
        });
      case 'unavailable':
        setState(() {
          _busy = false;
          _biometricAvailable = false;
          _error = _hasRecoveryCode
              ? 'Biometrics are unavailable. Use your recovery code.'
              : 'Biometrics are unavailable and no recovery code is configured.';
        });
      default:
        setState(() {
          _busy = false;
          _error = _hasRecoveryCode
              ? 'Biometric recovery failed. Use your recovery code.'
              : 'Biometric recovery failed. Try again.';
        });
    }
  }

  Future<void> _verifyCode() async {
    if (_busy) return;
    final input = _codeController.text;
    if (input.trim().isEmpty) {
      setState(() => _error = 'Enter your recovery code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    RecoveryVerification result;
    try {
      result = await widget.controller.recoveryService.verifyCode(input);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not verify the recovery code. Please try again.';
      });
      return;
    }
    if (!mounted) return;
    if (result.isSuccess) {
      _codeController.clear();
      setState(() {
        _busy = false;
        _error = null;
        _step = _RecoveryStep.chooseType;
      });
      return;
    }
    _codeController.clear();
    setState(() {
      _busy = false;
      _error = result.message;
    });
    _codeFocus.requestFocus();
  }

  Future<void> _save(String credential) async {
    final type = _newType;
    if (type == null) return;
    // Throwing is intentional: CredentialSetupPanel catches storage/crypto
    // failures and keeps the user on the confirmation step. The previous
    // credential stays valid when replaceCredential fails.
    await widget.controller.completeRecovery(
      type: type,
      credential: credential,
    );
    if (!mounted) return;

    bool hasRecovery = false;
    try {
      hasRecovery = await widget.controller.recoveryService.hasRecoveryCode();
    } catch (_) {
      // The credential replacement already succeeded; a failed read must not
      // pretend it did not. Fall through to the normal completion path.
      hasRecovery = true;
    }
    if (!mounted) return;

    if (!hasRecovery && !_factorsReadFailed) {
      // Existing installation recovered with biometrics: give the user the
      // recovery code they never had. It is still their explicit choice
      // whether to store it (the screen offers a warned skip).
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              RecoveryCodeSetupScreen(controller: widget.controller),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${type.title} saved. Unlock with your new '
          '${type.credentialNoun} now.',
        ),
        backgroundColor: AppColors.success,
      ),
    );
    Navigator.of(context).pop(true);
  }

  void _onBack() {
    if (_busy) return;
    switch (_step) {
      case _RecoveryStep.options:
        Navigator.of(context).maybePop();
      case _RecoveryStep.code:
        setState(() {
          _step = _RecoveryStep.options;
          _error = null;
          _codeController.clear();
        });
      case _RecoveryStep.chooseType:
        setState(() {
          _step = _RecoveryStep.options;
          _newType = null;
        });
      case _RecoveryStep.configure:
        setState(() {
          _step = _RecoveryStep.chooseType;
          _newType = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      // Back is handled explicitly so an authorised-but-not-saved recovery
      // simply returns to the lock screen without changing anything.
      canPop: _step == _RecoveryStep.options && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('Recover access'),
          leading: IconButton(
            tooltip: 'Back',
            onPressed: _busy ? null : _onBack,
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + keyboard),
            child: _buildStep(),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _RecoveryStep.options:
        return _buildOptions();
      case _RecoveryStep.code:
        return _buildCodeEntry();
      case _RecoveryStep.chooseType:
        return _buildChooseType();
      case _RecoveryStep.configure:
        return _buildConfigure();
    }
  }

  Widget _buildOptions() {
    final hasBiometric = _biometricAvailable && widget.requestBiometric != null;
    final noFactors = !_loadingFactors && !hasBiometric && !_hasRecoveryCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        const Center(child: AppLogo(size: 56)),
        const SizedBox(height: 20),
        const Text(
          'Verify it\'s you',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Recovery proves you own this device before any lock is changed. '
          'Your current lock and protected apps stay exactly as they are '
          'until a new credential is saved.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 22),
        if (_loadingFactors)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          if (hasBiometric)
            BlueLockCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.fingerprint_rounded,
                  color: AppColors.primary,
                  size: 28,
                ),
                title: const Text(
                  'Recover with biometrics',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: const Text(
                  'Use the fingerprint or face enrolled on this device.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                trailing: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.chevron_right,
                        color: AppColors.textSecondary,
                      ),
                onTap: _busy ? null : _useBiometric,
              ),
            ),
          if (hasBiometric && _hasRecoveryCode) const SizedBox(height: 12),
          if (_hasRecoveryCode)
            BlueLockCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.key_rounded,
                  color: AppColors.primary,
                  size: 26,
                ),
                title: const Text(
                  'Use recovery code',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: const Text(
                  'Enter the 16-character code you saved during setup.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: AppColors.textSecondary,
                ),
                onTap: _busy
                    ? null
                    : () => setState(() {
                        _step = _RecoveryStep.code;
                        _error = null;
                      }),
              ),
            ),
          if (noFactors) _NoRecoveryFactorCard(controller: widget.controller),
          if (_factorsReadFailed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Could not read the recovery configuration from secure '
                'storage. Your current lock is unchanged.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.danger),
              ),
            ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.danger,
            ),
          ),
        ],
        const SizedBox(height: 22),
        SecondaryButton(
          label: 'Cancel',
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _buildCodeEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        const Text(
          'Enter recovery code',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Enter the 16-character code you saved. Hyphens and spaces are '
          'ignored, and capitalisation does not matter.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeController,
          focusNode: _codeFocus,
          autofocus: true,
          obscureText: _obscureCode,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _verifyCode(),
          style: const TextStyle(
            fontSize: 18,
            letterSpacing: 1.4,
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: 'Recovery code',
            hintText: RecoveryCode.format('AAAAAAAAAAAAAAAA'),
            prefixIcon: const Icon(Icons.key_rounded, color: AppColors.primary),
            suffixIcon: IconButton(
              tooltip: _obscureCode
                  ? 'Show recovery code'
                  : 'Hide recovery code',
              onPressed: () => setState(() => _obscureCode = !_obscureCode),
              icon: Icon(
                _obscureCode
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 38,
          child: _error == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.danger,
                    ),
                  ),
                ),
        ),
        PrimaryButton(
          label: _busy ? 'Checking...' : 'Verify code',
          enabled: !_busy,
          onPressed: _verifyCode,
        ),
        const SizedBox(height: 4),
        SecondaryButton(
          label: 'Cancel',
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _buildChooseType() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        const Text(
          'Choose a new lock type',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'You\'ve verified it\'s you. Your current credential stays active '
          'until you configure and confirm the new one.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        LockTypeOptionList(
          onSelected: (type) => setState(() {
            _newType = type;
            _step = _RecoveryStep.configure;
          }),
        ),
        const SizedBox(height: 10),
        SecondaryButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _buildConfigure() {
    final type = _newType!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        Text(
          'Set up your ${type.title}',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Everything is saved only after you confirm. Cancel now and your '
          'existing lock remains active.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 16),
        CredentialSetupPanel(
          type: type,
          firstHeading: type.setupHeading,
          firstDescription: type.setupDescription,
          confirmHeading: type.confirmHeading,
          confirmDescription: type.confirmDescription,
          onConfirmed: _save,
        ),
      ],
    );
  }
}

/// Explains clearly that no in-app recovery factor exists. It deliberately
/// offers no "reset" button: the credential and protection state stay intact.
class _NoRecoveryFactorCard extends StatelessWidget {
  const _NoRecoveryFactorCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x33D97706)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 20,
                color: AppColors.warning,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No recovery method is configured',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'This device has no enrolled biometrics available to Blue Lock '
            'and no recovery code was created. Your current lock therefore '
            'stays active - there is no in-app way to bypass it.\n\n'
            'If you truly cannot unlock, Android Settings lets you clear Blue '
            'Lock\'s app data. That removes the credential, every protected-app '
            'selection and all settings, and stops protection until you set '
            'Blue Lock up again. Android does not allow an app to prevent data '
            'clearing or uninstall, so this recovery limitation is platform-'
            'enforced, not something Blue Lock can remove.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => controller.native.openAppSettings(),
            icon: const Icon(
              Icons.settings_outlined,
              size: 18,
              color: AppColors.primary,
            ),
            label: const Text(
              'Open Android app settings',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
