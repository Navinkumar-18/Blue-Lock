import 'package:flutter/material.dart';

import '../../core/authentication/authentication_type.dart';
import '../../core/authentication/credential_rules.dart';
import 'password_entry_panel.dart';
import 'pattern_lock_panel.dart';
import 'pin_entry_panel.dart';

/// Renders the correct input for the selected authentication type and
/// exposes a single error/clear API to the screens.
///
/// Pattern callbacks are canonicalised with [CredentialRules.encodePattern]
/// so the verifier always receives the same deterministic representation.
class CredentialEntryPanel extends StatefulWidget {
  const CredentialEntryPanel({
    super.key,
    required this.type,
    required this.heading,
    required this.description,
    required this.actionLabel,
    required this.onCompleted,
    this.errorText,
    this.forgotLabel,
    this.onForgot,
    this.showAction = true,
  });

  final AuthenticationType type;
  final String heading;
  final String description;
  final String actionLabel;
  final ValueChanged<String> onCompleted;
  final String? errorText;
  final String? forgotLabel;
  final VoidCallback? onForgot;
  final bool showAction;

  @override
  State<CredentialEntryPanel> createState() => CredentialEntryPanelState();
}

class CredentialEntryPanelState extends State<CredentialEntryPanel> {
  final GlobalKey<PinEntryPanelState> _pinKey = GlobalKey<PinEntryPanelState>();
  final GlobalKey<PatternLockPanelState> _patternKey =
      GlobalKey<PatternLockPanelState>();
  final GlobalKey<PasswordEntryPanelState> _passwordKey =
      GlobalKey<PasswordEntryPanelState>();

  void showError(String message) {
    switch (widget.type) {
      case AuthenticationType.pin4Digit:
      case AuthenticationType.pin6Digit:
        _pinKey.currentState?.showError(message);
      case AuthenticationType.pattern:
        _patternKey.currentState?.showError(message);
      case AuthenticationType.password:
        _passwordKey.currentState?.showError(message);
    }
  }

  void clear() {
    _pinKey.currentState?.clear();
    _patternKey.currentState?.clear();
    _passwordKey.currentState?.clear();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.type) {
      case AuthenticationType.pin4Digit:
      case AuthenticationType.pin6Digit:
        return PinEntryPanel(
          key: _pinKey,
          length: widget.type.pinLength!,
          heading: widget.heading,
          description: widget.description,
          actionLabel: widget.actionLabel,
          errorText: widget.errorText,
          onCompleted: widget.onCompleted,
          forgotLabel: widget.forgotLabel,
          onForgot: widget.onForgot,
          showAction: widget.showAction,
        );
      case AuthenticationType.pattern:
        return PatternLockPanel(
          key: _patternKey,
          heading: widget.heading,
          description: widget.description,
          actionLabel: widget.actionLabel,
          errorText: widget.errorText,
          onCompleted: (dots) =>
              widget.onCompleted(CredentialRules.encodePattern(dots)),
          forgotLabel: widget.forgotLabel,
          onForgot: widget.onForgot,
          showAction: widget.showAction,
        );
      case AuthenticationType.password:
        return PasswordEntryPanel(
          key: _passwordKey,
          heading: widget.heading,
          description: widget.description,
          actionLabel: widget.actionLabel,
          errorText: widget.errorText,
          onSubmitted: widget.onCompleted,
          forgotLabel: widget.forgotLabel,
          onForgot: widget.onForgot,
          showAction: widget.showAction,
          autofocus: false,
        );
    }
  }
}
