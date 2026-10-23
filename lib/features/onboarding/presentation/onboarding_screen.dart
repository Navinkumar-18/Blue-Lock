import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/buttons.dart';

/// Onboarding: heading, description, illustration and feature items with
/// "Get Started" and returning-user actions.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Center(child: AppLogo(size: 84)),
              const SizedBox(height: 32),
              const Text(
                'Keep your apps private',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Choose the apps you want to protect and unlock them with a '
                'PIN, pattern or password.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 28),
              const _FeatureItem(
                icon: Icons.apps_outlined,
                title: 'Pick any app',
                subtitle: 'Select installed apps to protect with one tap.',
              ),
              const _FeatureItem(
                icon: Icons.lock_outline_rounded,
                title: 'Choose your lock',
                subtitle: 'A 4 or 6-digit PIN, a pattern, or a password.',
              ),
              const _FeatureItem(
                icon: Icons.shield_outlined,
                title: 'Stay in control',
                subtitle: 'Change your lock and relock policy anytime.',
              ),
              const Spacer(),
              PrimaryButton(
                label: 'Get Started',
                onPressed: () => Navigator.of(context)
                    .pushReplacementNamed('/choose-lock-type'),
              ),
              if (controller.pinService.hasPinSync) ...[
                const SizedBox(height: 4),
                SecondaryButton(
                  label: controller.authType.isPin
                      ? 'I already have a PIN'
                      : 'I already have a lock',
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/enter-pin'),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  const _FeatureItem({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.paleBlueSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
