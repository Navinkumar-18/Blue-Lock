import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'buttons.dart';
import 'numeric_keypad.dart';
import 'pin_indicators.dart';

/// Reusable PIN entry block: heading, explanation, four masked indicators,
/// numeric keypad with backspace, error message and primary action.
class PinEntryPanel extends StatefulWidget {
  const PinEntryPanel({
    super.key,
    required this.heading,
    required this.description,
    required this.actionLabel,
    required this.onCompleted,
    this.errorText,
    this.onInputChanged,
    this.forgotLabel,
    this.onForgot,
    this.showAction = true,
  });

  final String heading;
  final String description;
  final String actionLabel;
  final ValueChanged<String> onCompleted;
  final String? errorText;
  final ValueChanged<String>? onInputChanged;
  final String? forgotLabel;
  final VoidCallback? onForgot;
  final bool showAction;

  @override
  State<PinEntryPanel> createState() => PinEntryPanelState();
}

class PinEntryPanelState extends State<PinEntryPanel> {
  static const int pinLength = 4;

  String _pin = '';
  String? _localError;

  String get pin => _pin;

  @override
  void didUpdateWidget(covariant PinEntryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorText != null && widget.errorText != oldWidget.errorText) {
      _pin = '';
      _localError = null;
    }
  }

  void clear() {
    setState(() {
      _pin = '';
      _localError = null;
    });
    widget.onInputChanged?.call(_pin);
  }

  void showError(String message) {
    setState(() {
      _localError = message;
      _pin = '';
    });
    widget.onInputChanged?.call(_pin);
  }

  void _onDigit(String digit) {
    if (_pin.length >= pinLength) return;
    setState(() {
      _pin += digit;
      _localError = null;
    });
    widget.onInputChanged?.call(_pin);
    if (_pin.length == pinLength) {
      widget.onCompleted(_pin);
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _localError = null;
    });
    widget.onInputChanged?.call(_pin);
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
        const SizedBox(height: 28),
        PinIndicators(
          length: pinLength,
          filled: _pin.length,
          error: error != null,
        ),
        SizedBox(
          height: 28,
          child: error == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.danger,
                    ),
                  ),
                ),
        ),
        NumericKeypad(onDigit: _onDigit, onBackspace: _onBackspace),
        const SizedBox(height: 12),
        if (widget.showAction)
          PrimaryButton(
            label: widget.actionLabel,
            enabled: _pin.length == pinLength,
            onPressed: () {
              if (_pin.length == pinLength) widget.onCompleted(_pin);
            },
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
