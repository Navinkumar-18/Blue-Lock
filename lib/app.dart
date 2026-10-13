import 'package:flutter/material.dart';

import 'core/state/app_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/perf_log.dart';
import 'features/app_lock/presentation/app_lock_screen.dart';
import 'features/authentication/presentation/change_pin_screen.dart';
import 'features/authentication/presentation/confirm_pin_screen.dart';
import 'features/authentication/presentation/create_pin_screen.dart';
import 'features/authentication/presentation/enter_pin_screen.dart';
import 'features/dashboard/presentation/home_shell.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';
import 'features/onboarding/presentation/splash_screen.dart';

/// Root widget: theming, routing and the shared [AppController].
class BlueLockApp extends StatelessWidget {
  const BlueLockApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blue Lock',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      onGenerateRoute: (settings) {
        final name = settings.name ?? '/';
        // Native LockActivity launches with initial route "lock/<package>".
        if (name.startsWith('/lock/')) {
          final packageName = name.substring('/lock/'.length);
          return MaterialPageRoute(
            builder: (_) => AppLockScreen(
              packageName: packageName,
              controller: controller,
            ),
            settings: settings,
          );
        }
        switch (name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => SplashScreen(controller: controller),
              settings: settings,
            );
          case '/onboarding':
            return MaterialPageRoute(
              builder: (_) => OnboardingScreen(controller: controller),
              settings: settings,
            );
          case '/create-pin':
            return MaterialPageRoute(
              builder: (_) => CreatePinScreen(
                // Persist only after the user confirms the matching PIN.
                onPinCreated: (pin) {
                  navigatorKey.currentState
                      ?.pushReplacementNamed('/confirm-pin', arguments: pin);
                },
              ),
              settings: settings,
            );
          case '/confirm-pin':
            final firstPin = settings.arguments as String? ?? '';
            return MaterialPageRoute(
              builder: (_) => ConfirmPinScreen(
                firstPin: firstPin,
                onConfirmed: (pin) async {
                  // Required setup operations first; navigate as soon as
                  // they complete. Any failure propagates to the screen and
                  // leaves the user on it - onboarding is never marked done
                  // unless the verifier actually persisted.
                  await controller.pinService.createPin(pin);
                  PerfLog.mark('confirm: verifier persisted');
                  await controller.markOnboardingDone();
                  PerfLog.mark('confirm: onboarding flag persisted');
                  navigatorKey.currentState
                      ?.pushNamedAndRemoveUntil('/home', (_) => false);
                  PerfLog.mark('confirm: navigation to /home issued');
                },
              ),
              settings: settings,
            );
          case '/enter-pin':
            return MaterialPageRoute(
              builder: (_) => EnterPinScreen(
                pinService: controller.pinService,
                onVerified: () async {
                  await controller.markOnboardingDone();
                  navigatorKey.currentState
                      ?.pushNamedAndRemoveUntil('/home', (_) => false);
                },
              ),
              settings: settings,
            );
          case '/change-pin':
            return MaterialPageRoute(
              builder: (_) => ChangePinScreen(pinService: controller.pinService),
              settings: settings,
            );
          case '/home':
            return MaterialPageRoute(
              builder: (_) => HomeShell(controller: controller),
              settings: settings,
            );
          default:
            return MaterialPageRoute(
              builder: (_) => SplashScreen(controller: controller),
              settings: settings,
            );
        }
      },
      navigatorKey: navigatorKey,
      home: SplashScreen(controller: controller),
    );
  }

  /// Global navigator key so callbacks (e.g. PIN created) can navigate.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
}
