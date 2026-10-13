import 'package:flutter/material.dart';

/// Blue Lock design tokens extracted from the Stitch reference description:
/// white / very light backgrounds, indigo-blue-purple accents, pale lavender
/// highlights, dark readable text, subtle borders, rounded cards.
class AppColors {
  AppColors._();

  static const Color background = Color(0xFFF7F8FC);
  static const Color surface = Colors.white;
  static const Color primary = Color(0xFF4F46E5);
  static const Color primaryDark = Color(0xFF4338CA);
  static const Color accent = Color(0xFF6366F1);
  static const Color lavender = Color(0xFFEEF2FF);
  static const Color lavenderStrong = Color(0xFFE0E7FF);
  static const Color border = Color(0xFFE2E8F0);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color success = Color(0xFF059669);
  static const Color successBg = Color(0xFFECFDF5);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerBg = Color(0xFFFEF2F2);
  static const Color warning = Color(0xFFD97706);
  static const Color warningBg = Color(0xFFFFFBEB);
  static const Color keypadKey = Color(0xFFF1F5F9);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.textPrimary),
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return const Color(0xFF94A3B8);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.primary;
          return const Color(0xFFE2E8F0);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
    );
  }
}
