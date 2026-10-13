import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Primary filled button matching the Stitch design: indigo, rounded,
/// ~54px tall.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onPressed != null;
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: FilledButton(
        onPressed: active ? onPressed : null,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          disabledBackgroundColor: AppColors.lavenderStrong,
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: icon == null
            ? Text(label)
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                  Text(label),
                ],
              ),
      ),
    );
  }
}

/// Outlined secondary button (e.g. "I already have a PIN").
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      ),
    );
  }
}
