import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Blue Lock branding logo displaying the official app logo asset.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 88});

  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.27;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.25),
            blurRadius: size * 0.25,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/app_logo.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

/// Circular app icon viewer for installed-app icons with letter fallback.
class AppIconView extends StatelessWidget {
  const AppIconView({
    super.key,
    required this.label,
    required this.iconBytes,
    this.size = 44,
  });

  final String label;
  final Uint8List? iconBytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bytes = iconBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.27),
      child: SizedBox(
        width: size,
        height: size,
        child: bytes != null && bytes.isNotEmpty
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : ColoredBox(
                color: AppColors.paleBlueSoft,
                child: Center(
                  child: Text(
                    label.isEmpty ? '?' : label.characters.first.toUpperCase(),
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: size * 0.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
