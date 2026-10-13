import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../models/installed_app.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';

/// Screen L: confirmation shown after an app is added to the protected list.
class ProtectionSuccessScreen extends StatelessWidget {
  const ProtectionSuccessScreen({
    super.key,
    required this.controller,
    required this.app,
  });

  final AppController controller;
  final InstalledApp app;

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
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.successBg,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 40, color: AppColors.success),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'App added successfully',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This app now requires your PIN to open.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              BlueLockCard(
                child: Row(
                  children: [
                    AppIconView(
                      label: app.label,
                      iconBytes: app.iconBytes,
                      size: 48,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            app.packageName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const StatusPill(
                      label: 'Protected',
                      tone: StatusTone.neutral,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              PrimaryButton(
                label: 'Done',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 6),
              SecondaryButton(
                label: 'Protect another app',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
