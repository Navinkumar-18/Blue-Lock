import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Row of PIN dots. Filled blue when a digit is entered; red in error state.
class PinIndicators extends StatelessWidget {
  const PinIndicators({
    super.key,
    required this.length,
    required this.filled,
    this.error = false,
    this.dotSize = 16,
  });

  final int length;
  final int filled;
  final bool error;
  final double dotSize;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.danger : AppColors.primary;
    return Semantics(
      liveRegion: true,
      label: error
          ? 'PIN error, $filled of $length digits entered'
          : '$filled of $length digits entered',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(length, (index) {
          final isFilled = index < filled;
          return Container(
            width: dotSize,
            height: dotSize,
            margin: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFilled ? color : Colors.transparent,
              border: Border.all(
                color: isFilled ? color : AppColors.border,
                width: 2,
              ),
            ),
          );
        }),
      ),
    );
  }
}
