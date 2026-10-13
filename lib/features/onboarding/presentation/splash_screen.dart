import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';

/// Splash: Blue Lock mark, name and tagline, then routes to onboarding or
/// the dashboard depending on stored state.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1300), _advance);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _advance() {
    if (!mounted) return;
    final c = widget.controller;
    final needsSetup = !c.onboardingDone || !c.hasPin;
    Navigator.of(context).pushReplacementNamed(needsSetup ? '/onboarding' : '/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppLogo(size: 96),
            const SizedBox(height: 24),
            const Text(
              'Blue Lock',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your apps. Your privacy.',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
