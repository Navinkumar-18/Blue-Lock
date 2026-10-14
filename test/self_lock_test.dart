import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/app.dart';
import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/core/utils/pin_crypto.dart';
import 'package:blue_lock/features/app_lock/presentation/app_lock_screen.dart';
import 'package:blue_lock/features/app_lock/presentation/self_lock_screen.dart';
import 'package:blue_lock/features/dashboard/presentation/home_shell.dart';
import 'package:blue_lock/features/onboarding/presentation/onboarding_screen.dart';

/// Blue Lock self-lock (app-entry authentication gate) coverage.
///
/// The native LockPrefs/NativeBridge self-session contract is modelled by
/// [FakeSelfSession] so the gate can be driven hermetically:
///
///  A. First launch: onboarding + PIN creation complete without a gate.
///  B. Reopening Blue Lock requests authentication when the policy requires.
///  C. Enabled/available biometrics trigger exactly one system prompt.
///  D. PIN fallback unlocks when biometrics are cancelled.
///  E. An incorrect PIN never unlocks.
///  F. Immediate relock on leaving the app.
///  G. 30s / 1min / 5min timeout policies.
///  H. LockActivity's third-party lock flow is untouched by the gate.
///  I. Repeated lifecycle events never stack prompts or lock screens.
Future<Uint8List> _testDerive(String pin, Uint8List salt) async =>
    PinCrypto.deriveVerifier(pin, salt);

/// Stand-in for the native self-session + biometric bridge.
///
/// Mirrors LockPrefs: immediate sessions die when Blue Lock leaves the
/// foreground, timed sessions are re-stamped on leave and expire purely on
/// elapsed time (no Dart timer anywhere).
class FakeSelfSession {
  int relockTimeout = 0;
  bool unlocked = false;
  DateTime now = DateTime(2026, 1, 1, 9);
  DateTime? expiry;

  int unlockCalls = 0;
  int backgroundCalls = 0;
  int biometricPrompts = 0;

  /// 'success' | 'user_cancel' | 'unavailable' | 'failed'
  String biometricOutcome = 'user_cancel';
  bool biometricAvailable = false;

  void grant() {
    unlockCalls++;
    unlocked = true;
    expiry = relockTimeout <= 0
        ? null
        : now.add(Duration(seconds: relockTimeout));
  }

  void background() {
    backgroundCalls++;
    // Mirrors LockPrefs.onSelfBackgrounded: only a still-valid session is
    // retained for the configured window; an invalid one is never revived.
    if (relockTimeout <= 0 || !check()) {
      unlocked = false;
      expiry = null;
    } else {
      expiry = now.add(Duration(seconds: relockTimeout));
    }
  }

  bool check() {
    if (!unlocked) return false;
    if (relockTimeout <= 0) return true; // still the live process
    final until = expiry;
    return until != null && now.isBefore(until);
  }

  void advanceSeconds(int seconds) => now = now.add(Duration(seconds: seconds));

  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'isSelfUnlocked':
        return check();
      case 'unlockSelf':
        grant();
        return null;
      case 'lockSelf':
        unlocked = false;
        expiry = null;
        return null;
      case 'setRelockTimeout':
        relockTimeout = (call.arguments as num).toInt();
        return null;
      case 'selfBackgrounded':
        background();
        return null;
      case 'authenticateBiometric':
        biometricPrompts++;
        if (biometricOutcome == 'success') return true;
        throw PlatformException(
          code: biometricOutcome == 'failed' ? 'auth_failed' : biometricOutcome,
        );
      case 'getBiometricStatus':
        return <String, dynamic>{
          'available': biometricAvailable,
          'enrolled': biometricAvailable,
          'enabled': biometricAvailable,
        };
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const lockChannel = MethodChannel('com.bluelock.app/lock');
  final secureStore = <String, String>{};
  final lockCalls = <MethodCall>[];

  late FakeSelfSession session;

  setUp(() {
    secureStore.clear();
    lockCalls.clear();
    SharedPreferences.setMockInitialValues({});
    session = FakeSelfSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, session.handle);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockChannel, (call) async {
      lockCalls.add(call);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map).cast<String, dynamic>();
      switch (call.method) {
        case 'read':
          return secureStore[args['key']];
        case 'write':
          secureStore[args['key']] = args['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(args['key']);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(args['key']);
      }
      return null;
    });
  });

  /// Persists a PIN and finished onboarding straight into storage, so the
  /// next [makeController] boots as a fully set-up install (returning user).
  Future<void> seedPin({String pin = '1234'}) async {
    final storage = AppStorage();
    await storage.init();
    final seed = AppController(
      storage: storage,
      native: NativeBridge(),
      services: const AppControllerServices(derive: _testDerive),
    );
    await seed.pinService.createPin(pin);
    await storage.setOnboardingDone(true);
  }

  /// Persists the automatic-relock policy, mirroring what a real install has
  /// stored before the controller boots.
  Future<void> seedRelockTimeout(int seconds) async {
    final storage = AppStorage();
    await storage.init();
    await storage.setRelockTimeoutSeconds(seconds);
  }

  /// Builds a controller. By default the install is already set up (PIN
  /// stored + onboarding done), which is the state every post-setup screen
  /// runs in. Pass `withPin: false` to boot a first-run install instead.
  Future<AppController> makeController({bool withPin = true}) async {
    if (withPin) await seedPin();
    final storage = AppStorage();
    await storage.init();
    final controller = AppController(
      storage: storage,
      native: NativeBridge(),
      services: const AppControllerServices(derive: _testDerive),
    );
    await controller.init();
    return controller;
  }

  Future<void> boot(
    WidgetTester tester,
    AppController controller, {
    bool selfLockHost = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // Same configuration mirror main.dart runs before runApp for the
    // normal (non-LockActivity) boot path.
    await controller.native.setRelockTimeout(controller.relockTimeoutSeconds);
    await tester.pumpWidget(BlueLockApp(
      controller: controller,
      selfLockHost: selfLockHost,
    ));
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
  }

  /// Boots the engine exactly like the native LockActivity does: the first
  /// route pushed is "lock/<package>", the splash never advances (its timer
  /// checks that it is still the current route).
  Future<void> bootLockEngine(
    WidgetTester tester,
    AppController controller,
    String packageName, {
    bool selfLockHost = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BlueLockApp(
      controller: controller,
      selfLockHost: selfLockHost,
    ));
    BlueLockApp.navigatorKey.currentState!.pushNamed('lock/$packageName');
    await tester.pumpAndSettle();
  }

  Future<void> enterDigits(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() isDone, {
    int maxIterations = 250,
  }) async {
    for (var i = 0; i < maxIterations && !isDone(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Completes first-time setup (onboarding -> create -> confirm PIN).
  Future<AppController> completeSetup(
    WidgetTester tester, {
    String pin = '1234',
    int? relockTimeout,
  }) async {
    if (relockTimeout != null) await seedRelockTimeout(relockTimeout);
    final controller = await makeController(withPin: false);
    await boot(tester, controller);
    expect(find.text('Keep your apps private'), findsOneWidget);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await enterDigits(tester, pin);
    await tester.pumpAndSettle();
    await enterDigits(tester, pin);
    await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
    return controller;
  }

  /// Simulates Blue Lock leaving the foreground and coming back.
  Future<void> backgroundAndReturn(WidgetTester tester) async {
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      // ignore: invalid_use_of_protected_member
      tester.binding.handleAppLifecycleStateChanged(state);
      if (state == AppLifecycleState.resumed) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }
  }

  group('A. first launch', () {
    testWidgets('onboarding and PIN creation complete without an auth gate',
        (tester) async {
      final controller = await makeController(withPin: false);
      await boot(tester, controller);

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(SelfLockScreen), findsNothing);

      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      await enterDigits(tester, '1234');
      await tester.pumpAndSettle();
      await enterDigits(tester, '1234');
      await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
      await tester.pumpAndSettle();

      expect(find.byType(HomeShell), findsOneWidget,
          reason: 'setup must land on the dashboard, not on a lock screen');
      expect(find.byType(SelfLockScreen), findsNothing);
      expect(session.unlockCalls, 1,
          reason: 'creating a PIN counts as the first authentication');
    });
  });

  group('B. reopening the app', () {
    testWidgets('a fresh cold start with a stored PIN requires authentication',
        (tester) async {
      await completeSetup(tester);

      // Simulate the process being recreated: native session is gone.
      session.unlocked = false;
      session.expiry = null;
      await tester.pumpWidget(const SizedBox.shrink());
      final controller = await makeController();
      await boot(tester, controller);

      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing,
          reason: 'dashboard must not be reachable before authentication');
      expect(find.text('Change PIN'), findsNothing);
    });

    testWidgets('deep links cannot bypass the gate', (tester) async {
      final controller = await completeSetup(tester);
      session.unlocked = false;
      session.expiry = null;
      await controller.refreshSelfSession();

      BlueLockApp.navigatorKey.currentState!.pushNamed('/change-pin');
      await tester.pumpAndSettle();

      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.text('Enter current PIN'), findsNothing,
          reason: 'Change PIN must stay behind the authentication gate');
    });
  });

  group('C. biometrics', () {
    testWidgets('enabled biometrics trigger one system prompt and unlock',
        (tester) async {
      session.biometricAvailable = true;
      session.biometricOutcome = 'success';
      session.unlocked = false;
      final controller = await makeController();
      await boot(tester, controller);

      await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
      await tester.pumpAndSettle();

      expect(session.biometricPrompts, 1,
          reason: 'exactly one AndroidX BiometricPrompt request');
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(SelfLockScreen), findsNothing);
    });

    testWidgets('biometrics are not requested before a PIN exists',
        (tester) async {
      session.biometricAvailable = true;
      session.biometricOutcome = 'success';
      final controller = await makeController(withPin: false);
      await boot(tester, controller);

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(session.biometricPrompts, 0);
    });
  });

  group('D. PIN fallback', () {
    testWidgets('cancelling biometrics leaves the PIN keypad, which unlocks',
        (tester) async {
      session.biometricAvailable = true;
      session.biometricOutcome = 'user_cancel';
      session.unlocked = false;
      final controller = await makeController();
      await boot(tester, controller);

      await waitFor(tester, () => session.biometricPrompts == 1);
      await tester.pumpAndSettle();
      expect(find.byType(SelfLockScreen), findsOneWidget,
          reason: 'cancellation must never grant access');
      expect(find.byType(HomeShell), findsNothing);

      await enterDigits(tester, '1234');
      await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(session.unlockCalls, 1);
    });

    testWidgets('biometric failure shows the fallback message and stays locked',
        (tester) async {
      session.biometricAvailable = true;
      session.biometricOutcome = 'failed';
      session.unlocked = false;
      final controller = await makeController();
      await boot(tester, controller);

      await waitFor(tester,
          () => find.text('Biometric unlock failed. Enter your PIN.')
              .evaluate()
              .isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
    });
  });

  group('E. invalid PIN', () {
    testWidgets('an incorrect PIN keeps Blue Lock locked', (tester) async {
      session.unlocked = false;
      final controller = await makeController();
      await boot(tester, controller);
      expect(find.byType(SelfLockScreen), findsOneWidget);

      await enterDigits(tester, '0000');
      await waitFor(tester,
          () => find.text('Incorrect PIN. Try again.').evaluate().isNotEmpty);
      await tester.pumpAndSettle();

      expect(find.text('Incorrect PIN. Try again.'), findsWidgets);
      expect(find.byType(HomeShell), findsNothing);
      expect(session.unlockCalls, 0);
    });
  });

  group('F. immediate relock', () {
    testWidgets('leaving Blue Lock expires the session (policy = immediately)',
        (tester) async {
      session.relockTimeout = 0;
      await completeSetup(tester);
      expect(session.unlockCalls, 1);

      await backgroundAndReturn(tester);

      expect(session.unlocked, isFalse,
          reason: 'immediate policy must expire the session on leaving');
      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);

      // Unlocking again restores access - and only one gate instance exists.
      await enterDigits(tester, '1234');
      await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(SelfLockScreen), findsNothing);
    });
  });

  group('G. timeout policies', () {
    for (final timeout in const [30, 60, 300]) {
      testWidgets('after ${timeout}s the session is honoured until it expires',
          (tester) async {
        final controller = await completeSetup(tester, relockTimeout: timeout);

        await backgroundAndReturn(tester);
        session.advanceSeconds(timeout - 1);
        await backgroundAndReturn(tester);

        expect(find.byType(HomeShell), findsOneWidget,
            reason: 'returning within ${timeout}s must not re-prompt');
        expect(find.byType(SelfLockScreen), findsNothing);

        // Leave again and let the configured window run out.
        session.advanceSeconds(2);
        await backgroundAndReturn(tester);
        session.advanceSeconds(timeout + 1);
        await backgroundAndReturn(tester);

        expect(find.byType(SelfLockScreen), findsOneWidget,
            reason: 'after the ${timeout}s window authentication is required');
        expect(find.byType(HomeShell), findsNothing);
        expect(controller.relockTimeoutSeconds, timeout);
      });
    }

    testWidgets(
        'backgrounding from the lock screen never re-validates an expired '
        'session (no bypass via Home button)', (tester) async {
      final controller = await completeSetup(tester, relockTimeout: 30);
      session.unlocked = false; // expired while the user was away
      session.expiry = null;
      await controller.refreshSelfSession();

      await backgroundAndReturn(tester);
      await backgroundAndReturn(tester);

      expect(session.unlocked, isFalse,
          reason: 'leaving from the lock screen must not resurrect a session');
      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
    });
  });

  group('H. LockActivity flow', () {
    testWidgets(
        'the lock route renders the protected-app lock screen and never the '
        'self gate, even while Blue Lock itself is locked', (tester) async {
      session.unlocked = false;
      final controller = await makeController();
      // Booted by LockActivity: self-authentication must stay inert.
      await bootLockEngine(tester, controller, 'com.example.victim');

      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(find.byType(SelfLockScreen), findsNothing);
      expect(session.biometricPrompts, 0,
          reason: 'self-lock must not steal the protected-app prompt');
    });

    testWidgets('lifecycle events in the lock engine never touch the '
        'self-authentication session', (tester) async {
      session.unlocked = true;
      session.relockTimeout = 0;
      final controller = await makeController();
      await bootLockEngine(tester, controller, 'com.example.victim');

      await backgroundAndReturn(tester);

      expect(session.backgroundCalls, 0,
          reason: 'the lock engine must not expire Blue Lock sessions');
      expect(session.unlockCalls, 0);
      expect(session.unlocked, isTrue);
      expect(find.byType(AppLockScreen), findsOneWidget);
    });

    testWidgets('the lock route is not gated even in the main engine',
        (tester) async {
      session.unlocked = false;
      final controller = await makeController();
      await bootLockEngine(
        tester,
        controller,
        'com.example.victim',
        selfLockHost: true,
      );

      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(find.byType(SelfLockScreen), findsNothing);
    });
  });

  group('I. duplicate prompts', () {
    testWidgets(
        'repeated lifecycle events never stack prompts or lock screens',
        (tester) async {
      session.biometricAvailable = true;
      session.biometricOutcome = 'user_cancel';
      session.unlocked = false;
      final controller = await makeController();
      await boot(tester, controller);

      await waitFor(tester, () => session.biometricPrompts == 1);
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        await backgroundAndReturn(tester);
      }

      expect(session.biometricPrompts, 1,
          reason: 'auto biometric prompt must not repeat per lifecycle event');
      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
    });
  });

  group('J. existing protection is preserved', () {
    testWidgets(
        'third-party lock screen still authenticates with the shared PIN and '
        'never grants a Blue Lock session', (tester) async {
      session.unlocked = false;
      final controller = await makeController();
      await bootLockEngine(tester, controller, 'com.example.victim');

      await enterDigits(tester, '1234');
      await waitFor(
          tester, () => lockCalls.any((c) => c.method == 'unlock'));
      await tester.pumpAndSettle();

      final unlock = lockCalls.firstWhere((c) => c.method == 'unlock');
      expect(unlock.arguments, 'com.example.victim',
          reason: 'the protected-app session must be recorded, not ours');
      expect(session.unlockCalls, 0,
          reason: 'third-party unlock must not grant a Blue Lock session');
      expect(session.unlocked, isFalse);
      expect(find.byType(AppLockScreen), findsOneWidget,
          reason: 'native LockActivity, not Flutter, dismisses the screen');
    });

    testWidgets('a wrong PIN on the third-party lock screen is rejected',
        (tester) async {
      session.unlocked = false;
      final controller = await makeController();
      await bootLockEngine(tester, controller, 'com.example.victim');

      await enterDigits(tester, '0000');
      await waitFor(tester,
          () => find.text('Incorrect PIN. Try again.').evaluate().isNotEmpty);
      await tester.pumpAndSettle();

      expect(lockCalls.where((c) => c.method == 'unlock'), isEmpty);
      expect(find.text('Incorrect PIN. Try again.'), findsWidgets);
    });
  });
}
