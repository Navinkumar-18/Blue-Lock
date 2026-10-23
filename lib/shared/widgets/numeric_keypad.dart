import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 3x4 numeric keypad used on every PIN screen: digits 1-9, empty slot,
/// 0 and backspace.
///
/// Key sizes scale down on narrow screens (and up a little on tablets) while
/// keeping at least a 48 px touch target.
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  static const List<List<String>> _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', 'back'],
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 48;
        // Three keys plus two 8 px gaps. Clamp for phones and tablets.
        final keyWidth = ((available - 16) / 3).clamp(56.0, 88.0);
        final keyHeight = (keyWidth * 0.84).clamp(52.0, 68.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: _rows.map((row) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < row.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _keyFor(row[i], keyWidth, keyHeight),
                ],
              ],
            );
          }).toList(),
        );
      },
    );
  }

  Widget _keyFor(String key, double width, double height) {
    if (key.isEmpty) {
      return SizedBox(width: width, height: height);
    }
    if (key == 'back') {
      return _KeypadKey(
        onTap: onBackspace,
        semanticLabel: 'Delete last digit',
        width: width,
        height: height,
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
      width: width,
      height: height,
      child: Text(
        key,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _KeypadKey extends StatelessWidget {
  const _KeypadKey({
    required this.onTap,
    required this.semanticLabel,
    required this.width,
    required this.height,
    required this.child,
  });

  final VoidCallback onTap;
  final String semanticLabel;
  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: AppColors.keypadKey,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: width,
            height: height,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
