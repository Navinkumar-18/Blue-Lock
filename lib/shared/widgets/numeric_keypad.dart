import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 3x4 numeric keypad used on every PIN screen: digits 1-9, empty slot,
/// 0 and backspace.
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({super.key, required this.onDigit, required this.onBackspace});

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'back'],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows.map((row) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: row.map((key) {
            if (key.isEmpty) {
              return const SizedBox(width: 76, height: 64);
            }
            if (key == 'back') {
              return _KeypadKey(
                onTap: onBackspace,
                semanticLabel: 'Delete last digit',
                child: const Icon(
                  Icons.backspace_outlined,
                  size: 22,
                  color: AppColors.textSecondary,
                ),
              );
            }
            return _KeypadKey(
              onTap: () => onDigit(key),
              semanticLabel: 'Digit $key',
              child: Text(
                key,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            );
          }).toList(),
        );
      }).toList(),
    );
  }
}

class _KeypadKey extends StatelessWidget {
  const _KeypadKey({
    required this.onTap,
    required this.semanticLabel,
    required this.child,
  });

  final VoidCallback onTap;
  final String semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Material(
          color: AppColors.keypadKey,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(width: 76, height: 64, child: Center(child: child)),
          ),
        ),
      ),
    );
  }
}
