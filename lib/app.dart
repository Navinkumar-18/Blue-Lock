import 'package:flutter/material.dart';

import 'core/authentication/authentication_type.dart';
import 'core/state/app_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/perf_log.dart';
import 'features/app_lock/presentation/lock_host_screen.dart';
import 'features/app_lock/presentation/self_auth_gate.dart';
import 'features/authentication/presentation/change_lock_type_screen.dart';
import 'features/authentication/presentation/change_pin_screen.dart';
import 'features/authentication/presentation/choose_lock_type_screen.dart';
import 'features/authentication/presentation/create_credential_screen.dart';
import 'features/authentication/presentation/enter_pin_screen.dart';
import 'features/authentication/presentation/recovery_code_setup_screen.dart';
import 'features/dashboard/presentation/home_shell.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';
import 'features/onboarding/presentation/splash_screen.dart';

/// Root widget: theming, routing, the shared [AppController] and Blue Lock's
/// own app-entry authentication (relock policy applied on lifecycle changes).
class BlueLockApp extends StatefulWidget {
  const BlueLockApp({
    super.key,
    required this.controller,
    this.selfLockHost = true,
  });

  final AppController controller;

  /// False when this engine is booted by the native LockActivity to protect
  /// another application: the self-authentication gate and its lifecycle
  /// session handling must stay completely out of that flow.
  final bool selfLockHost;

  /// Global navigator key so callbacks (e.g. credential created) can navigate.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  State<BlueLockApp> createState() => _BlueLockAppState();
}

class _BlueLockAppState extends State<BlueLockApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.selfLockHost) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Blue Lock left the foreground: apply the relock policy natively.
        // Elapsed-time expiry is evaluated in native storage, so it keeps
        // counting while the app is backgrounded or its process is killed -
        // no Dart timer is involved.
        widget.controller.onSelfBackgrounded();
      case AppLifecycleState.resumed:
        widget.controller.refreshSelfSession();
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Sensitive screens stay behind Blue Lock's own authentication gate. The
  /// lock route is handled before this (it is its own authentication flow)
  /// and the splash exposes nothing, so neither is wrapped.
  Widget _guarded(Widget child) =>
      SelfAuthGate(controller: widget.controller, child: child);

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return MaterialApp(
      title: 'Blue Lock',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      onGenerateRoute: (settings) {
        final raw = settings.name ?? '/';
        // Native LockActivity boots this engine with initial route
        // "lock/<package>" (no leading slash - see LockActivity.getInitialRoute).
        // A leading slash would make Navigator.defaultGenerateInitialRoutes
        // split the route into segments and stack "/" and "/lock" underneath
        // the lock screen, so the native side deliberately omits it. Normalise
        // here so both forms resolve to the same lock screen instead of
        // falling through to the dashboard (the original bug: the user saw
        // the Blue Lock dashboard over the protected app).
        final name = raw.startsWith('/') ? raw : '/$raw';
        if (name.startsWith('/lock/')) {
          // Both "lock/<package>" (cold boot) and bare "lock/" (pre-warmed
          // cached engine) land on the lock host: it renders the credential
          // screen for the route package immediately, or waits for the native
          // "showLock" push when the engine was booted idle.
          final packageName = name.substring('/lock/'.length);
          return MaterialPageRoute(
            builder: (_) => LockHostScreen(
              controller: controller,
              initialPackage: packageName.isEmpty ? null : packageName,
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
              builder: (_) => _guarded(OnboardingScreen(controller: controller)),
              settings: settings,
            );
          case '/choose-lock-type':
            return MaterialPageRoute(
              builder: (_) => _guarded(const ChooseLockTypeScreen()),
              settings: settings,
            );
          case '/create-credential':
            final type = settings.arguments is AuthenticationType
                ? settings.arguments as AuthenticationType
                : AuthenticationType.pin4Digit;
            return MaterialPageRoute(
              builder: (_) => _guarded(CreateCredentialScreen(
                type: type,
                onConfirmed: (credential) async {
                  // Required setup operations first; navigate as soon as
                  // they complete. Any failure propagates to the screen and
                  // leaves the user on it - onboarding is never marked done
                  // unless the verifier actually persisted.
                  await controller.createCredential(
                    type: type,
                    credential: credential,
                  );
                  PerfLog.mark('confirm: verifier persisted');
                  await controller.markOnboardingDone();
                  PerfLog.mark('confirm: onboarding flag persisted');
                  // The user just proved the new credential: grant the self
                  // session so setup lands on the dashboard instead of
                  // immediately re-prompting. Any later open follows the
                  // relock policy.
                  await controller.grantSelfSession();
                  // Show the one-time recovery code before the dashboard.
                  // The user is already granted a session, so the gate does
                  // not cover this setup step.
                  BlueLockApp.navigatorKey.currentState
                      ?.pushNamedAndRemoveUntil('/recovery-setup', (_) => false);
                  PerfLog.mark('confirm: recovery-code step issued');
                },
              )),
              settings: settings,
            );
          case '/create-pin':
            // Legacy route: setup always goes through the lock-type chooser
            // so every entry point honours the same selected method.
            return MaterialPageRoute(
              builder: (_) => _guarded(const ChooseLockTypeScreen()),
              settings: settings,
            );
          case '/enter-pin':
            return MaterialPageRoute(
              builder: (_) => _guarded(EnterPinScreen(
                pinService: controller.pinService,
                onVerified: () async {
                  await controller.markOnboardingDone();
                  await controller.grantSelfSession();
                  BlueLockApp.navigatorKey.currentState
                      ?.pushNamedAndRemoveUntil('/home', (_) => false);
                },
              )),
              settings: settings,
            );
          case '/change-pin':
            return MaterialPageRoute(
              builder: (_) => _guarded(ChangePinScreen(
                  pinService: controller.pinService)),
              settings: settings,
            );
          case '/change-lock-type':
            return MaterialPageRoute(
              builder: (_) =>
                  _guarded(ChangeLockTypeScreen(controller: controller)),
              settings: settings,
            );
          case '/recovery-setup':
            return MaterialPageRoute(
              builder: (_) => _guarded(RecoveryCodeSetupScreen(
                controller: controller,
                isFirstRun: true,
                onFinished: () {
                  BlueLockApp.navigatorKey.currentState
                      ?.pushNamedAndRemoveUntil('/home', (_) => false);
                },
              )),
              settings: settings,
            );
          case '/home':
            return MaterialPageRoute(
              builder: (_) => _guarded(HomeShell(controller: controller)),
              settings: settings,
            );
          default:
            return MaterialPageRoute(
              builder: (_) => SplashScreen(controller: controller),
              settings: settings,
            );
        }
      },
      navigatorKey: BlueLockApp.navigatorKey,
      home: SplashScreen(controller: controller),
    );
  }
}
