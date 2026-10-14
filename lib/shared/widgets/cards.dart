import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// White rounded card with subtle border and shadow, per the Stitch design.
///
/// The white surface is painted by a [Material] (not a DecoratedBox) so that
/// descendant tiles (ListTile, SwitchListTile, InkWell) paint their own
/// backgrounds and ink ripples on the visible surface. A DecoratedBox color
/// above the nearest Material both hides ink and trips Flutter's ListTile
/// background assertion.
class BlueLockCard extends StatelessWidget {
  const BlueLockCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Container(
      width: double.infinity,
      // Shadow-only decoration: BoxDecoration.color stays null, so it does
      // not hide anything painted by the Material below it.
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? content
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                child: content,
              ),
      ),
    );
  }
}

/// Small status pill: green "Granted", amber "Missing", blue informational.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.tone});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      StatusTone.success => (AppColors.successBg, AppColors.success),
      StatusTone.warning => (AppColors.warningBg, AppColors.warning),
      StatusTone.danger => (AppColors.dangerBg, AppColors.danger),
      StatusTone.neutral => (AppColors.paleBlueSoft, AppColors.primary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

enum StatusTone { success, warning, danger, neutral }

/// Section title used above card groups ("Protection Status", ...).
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10, top: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}
