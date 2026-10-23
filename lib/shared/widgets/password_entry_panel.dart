import 'package:flutter/material.dart';

import '../../core/authentication/authentication_type.dart';
import '../../core/authentication/credential_rules.dart';
import '../../core/theme/app_theme.dart';
import 'buttons.dart';

/// Secure password entry for the lock/verify screens.
///
/// The full permitted character set is accepted, nothing is trimmed before
/// hashing, and submission only happens through the button or the keyboard's
/// done action.
class PasswordEntryPanel extends StatefulWidget {
  const PasswordEntryPanel({
    super.key,
    required this.heading,
    required this.description,
    required this.actionLabel,
    required this.onSubmitted,
    this.errorText,
    this.forgotLabel,
    this.onForgot,
    this.showAction = true,
    this.fieldLabel = 'Password',
    this.autofocus = false,
  });

  final String heading;
  final String description;
  final String actionLabel;
  final ValueChanged<String> onSubmitted;
  final String? errorText;
  final String? forgotLabel;
  final VoidCallback? onForgot;
  final bool showAction;
  final String fieldLabel;
  final bool autofocus;

  @override
  State<PasswordEntryPanel> createState() => PasswordEntryPanelState();
}

class PasswordEntryPanelState extends State<PasswordEntryPanel> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _obscure = true;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant PasswordEntryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorText != null && widget.errorText != oldWidget.errorText) {
      _clearText();
      _localError = null;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      _localError = null;
    });
  }

  void _clearText() {
    _controller.clear();
  }

  void clear() {
    setState(() {
      _localError = null;
      _controller.clear();
    });
  }

  void showError(String message) {
    setState(() {
      // Clear first: the controller listener resets _localError on every
      // change, so the message must be assigned after the clear or it would
      // be erased before the next frame.
      _controller.clear();
      _localError = message;
    });
    _focusNode.requestFocus();
  }

  void _submit() {
    final value = _controller.text;
    final error = CredentialRules.validate(
      // Password-specific bounds only; no PIN-style exact length.
      AuthenticationType.password,
      value,
    );
    if (error != null) {
      setState(() => _localError = error);
      return;
    }
    widget.onSubmitted(value);
  }

  @override
  Widget build(BuildContext context) {
    final error = _localError ?? widget.errorText;
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
          controller: _controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: widget.fieldLabel,
            prefixIcon: const Icon(
              Icons.lock_outline_rounded,
              color: AppColors.primary,
            ),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
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
        if (widget.showAction)
          PrimaryButton(
            label: widget.actionLabel,
            enabled: _controller.text.isNotEmpty,
            onPressed: _submit,
          ),
        if (widget.forgotLabel != null && widget.onForgot != null)
          TextButton(
            onPressed: widget.onForgot,
            child: Text(
              widget.forgotLabel!,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}
