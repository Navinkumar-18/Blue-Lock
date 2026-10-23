import 'package:flutter/material.dart';

import '../../core/authentication/authentication_type.dart';
import '../../core/authentication/credential_rules.dart';
import '../../core/theme/app_theme.dart';
import '../../features/authentication/services/pin_service.dart';
import 'buttons.dart';
import 'pattern_lock_panel.dart';
import 'pin_entry_panel.dart';

/// Two-step credential setup used by onboarding and Change Lock Type.
///
/// PIN and pattern are entered twice (matching the original PIN flow).
/// Passwords use a single form with password + confirmation fields.
class CredentialSetupPanel extends StatefulWidget {
  const CredentialSetupPanel({
    super.key,
    required this.type,
    required this.onConfirmed,
    this.firstHeading,
    this.firstDescription,
    this.confirmHeading,
    this.confirmDescription,
    this.mismatchMessage,
    this.sameCredentialMessage,
    this.saveErrorMessage,
    this.currentCredential,
  });

  final AuthenticationType type;
  final Future<void> Function(String credential) onConfirmed;

  final String? firstHeading;
  final String? firstDescription;
  final String? confirmHeading;
  final String? confirmDescription;
  final String? mismatchMessage;
  final String? sameCredentialMessage;
  final String? saveErrorMessage;

  /// Set when changing an existing credential: an identical new value is
  /// rejected before the confirmation step.
  final String? currentCredential;

  @override
  State<CredentialSetupPanel> createState() => _CredentialSetupPanelState();
}

class _CredentialSetupPanelState extends State<CredentialSetupPanel> {
  final GlobalKey<PinEntryPanelState> _pinKey = GlobalKey<PinEntryPanelState>();
  final GlobalKey<PatternLockPanelState> _patternKey =
      GlobalKey<PatternLockPanelState>();
  bool _confirming = false;
  bool _busy = false;
  String? _first;
  String? _error;

  String get _firstHeading =>
      widget.firstHeading ?? widget.type.setupHeading;
  String get _firstDescription =>
      widget.firstDescription ?? widget.type.setupDescription;
  String get _confirmHeading =>
      widget.confirmHeading ?? widget.type.confirmHeading;
  String get _confirmDescription =>
      widget.confirmDescription ?? widget.type.confirmDescription;
  String get _mismatchMessage =>
      widget.mismatchMessage ?? widget.type.mismatchMessage;
  String get _sameMessage =>
      widget.sameCredentialMessage ?? widget.type.sameCredentialMessage;
  String get _saveError =>
      widget.saveErrorMessage ?? widget.type.saveErrorMessage;

  void _showChildError(String message) {
    switch (widget.type) {
      case AuthenticationType.pin4Digit:
      case AuthenticationType.pin6Digit:
        _pinKey.currentState?.showError(message);
      case AuthenticationType.pattern:
        _patternKey.currentState?.showError(message);
      case AuthenticationType.password:
        break;
    }
  }

  Future<void> _onFirst(String credential) async {
    if (_busy) return;
    final validation = CredentialRules.validate(widget.type, credential);
    if (validation != null) {
      setState(() => _error = validation);
      _showChildError(validation);
      return;
    }
    if (widget.currentCredential != null &&
        widget.currentCredential == credential) {
      setState(() => _error = _sameMessage);
      _showChildError(_sameMessage);
      return;
    }
    setState(() {
      _first = credential;
      _error = null;
      _confirming = true;
    });
    // The same panel instance is reused for the confirmation step. Clear it
    // so the completed first entry cannot block the second entry (the PIN
    // panel ignores digits once full, and the pattern panel latches after
    // submission).
    _pinKey.currentState?.clear();
    _patternKey.currentState?.clear();
  }

  Future<void> _onConfirm(String credential) async {
    if (_busy) return;
    if (credential != _first) {
      setState(() => _error = _mismatchMessage);
      _showChildError(_mismatchMessage);
      return;
    }
    await _save(credential);
  }

  Future<void> _onPasswordSubmit(String password, String confirmation) async {
    if (_busy) return;
    final validation = CredentialRules.validate(widget.type, password);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (widget.currentCredential != null &&
        widget.currentCredential == password) {
      setState(() => _error = _sameMessage);
      return;
    }
    if (password != confirmation) {
      setState(() => _error = _mismatchMessage);
      return;
    }
    await _save(password);
  }

  Future<void> _save(String credential) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirmed(credential);
      // The caller normally navigates or closes the screen. If it does not,
      // leave the button disabled to prevent duplicate submissions.
    } on PinException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      _showChildError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _saveError;
      });
      _showChildError(_saveError);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.type.isPassword) {
      return _PasswordSetupForm(
        heading: _firstHeading,
        description: _firstDescription,
        error: _error,
        busy: _busy,
        onSubmit: _onPasswordSubmit,
      );
    }

    if (!_confirming) {
      return _buildFirstStep();
    }
    return _buildConfirmStep();
  }

  Widget _buildFirstStep() {
    if (widget.type.isPin) {
      return PinEntryPanel(
        key: _pinKey,
        length: widget.type.pinLength!,
        heading: _firstHeading,
        description: _firstDescription,
        actionLabel: 'Continue',
        errorText: _error,
        onCompleted: _onFirst,
      );
    }
    return PatternLockPanel(
      key: _patternKey,
      heading: _firstHeading,
      description: _firstDescription,
      actionLabel: 'Continue',
      errorText: _error,
      onCompleted: (dots) =>
          _onFirst(CredentialRules.encodePattern(dots)),
    );
  }

  Widget _buildConfirmStep() {
    if (widget.type.isPin) {
      return PinEntryPanel(
        key: _pinKey,
        length: widget.type.pinLength!,
        heading: _confirmHeading,
        description: _confirmDescription,
        actionLabel: _busy ? 'Saving...' : 'Confirm',
        errorText: _error,
        onCompleted: _onConfirm,
      );
    }
    return PatternLockPanel(
      key: _patternKey,
      heading: _confirmHeading,
      description: _confirmDescription,
      actionLabel: _busy ? 'Saving...' : 'Confirm',
      errorText: _error,
      onCompleted: (dots) =>
          _onConfirm(CredentialRules.encodePattern(dots)),
    );
  }
}

class _PasswordSetupForm extends StatefulWidget {
  const _PasswordSetupForm({
    required this.heading,
    required this.description,
    required this.error,
    required this.busy,
    required this.onSubmit,
  });

  final String heading;
  final String description;
  final String? error;
  final bool busy;
  final Future<void> Function(String password, String confirmation) onSubmit;

  @override
  State<_PasswordSetupForm> createState() => _PasswordSetupFormState();
}

class _PasswordSetupFormState extends State<_PasswordSetupForm> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void initState() {
    super.initState();
    _password.addListener(_rebuild);
    _confirmation.addListener(_rebuild);
  }

  @override
  void dispose() {
    _password.removeListener(_rebuild);
    _confirmation.removeListener(_rebuild);
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _submit() {
    if (widget.busy) return;
    widget.onSubmit(_password.text, _confirmation.text);
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.error;
    final canSubmit = _password.text.isNotEmpty &&
        _confirmation.text.isNotEmpty &&
        !widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          widget.heading,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.description,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _password,
          obscureText: _obscurePassword,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon:
                const Icon(Icons.lock_outline_rounded, color: AppColors.primary),
            suffixIcon: IconButton(
              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmation,
          obscureText: _obscureConfirmation,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Confirm password',
            prefixIcon:
                const Icon(Icons.lock_outline_rounded, color: AppColors.primary),
            suffixIcon: IconButton(
              tooltip:
                  _obscureConfirmation ? 'Show password' : 'Hide password',
              onPressed: () => setState(
                  () => _obscureConfirmation = !_obscureConfirmation),
              icon: Icon(
                _obscureConfirmation
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 34,
          child: error == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
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
          label: widget.busy ? 'Saving...' : 'Confirm',
          enabled: canSubmit,
          onPressed: _submit,
        ),
        const SizedBox(height: 6),
        const Text(
          'At least 4 characters. Spaces inside a password are preserved.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
