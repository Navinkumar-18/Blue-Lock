import 'dart:async';

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
import 'package:blue_lock/features/app_lock/services/lock_session.dart';

/// Regression coverage for the reported lock-screen contradiction:
/// "Biometric unlock unavailable. Enter your PIN." shown while the screen
/// still offered an "Unlock with biometrics" button.
///
/// Two defects are pinned here:
///  1. The message used to be chosen from the raw channel error code
///     ('unavailable'/'busy'), while the button used a status fetched only
///     once in initState - so a transient refusal displayed an
///     "unavailable" banner next to a usable button.
///  2. A hung platform call used to leave the prompt-active flag set
///     forever, disabling the button with no message at all.
///
/// The fake channel answers the same vocabulary as native code
/// (success / user_cancel / busy / unavailable / auth_failed / never).

Future<Uint8List> _testDerive(String pin, Uint8List salt) async =>
    PinCrypto.deriveVerifier(pin, salt);

class FakeLockChannel {
  /// Fresh availability as reported by every getBiometricStatus call.
  bool biometricUsable = true;

  /// When true, availability flips to unusable at prompt time - the
  /// device state change that makes a stale initState snapshot wrong.
  bool flipOnAuthenticate = false;

  /// success | user_cancel | busy | unavailable | failed | hang
  String outcome = 'user_cancel';

  int authenticateCalls = 0;
  int statusCalls = 0;
  final List<String> methods = <String>[];

  Future<dynamic> handle(MethodCall call) async {
    methods.add(call.method);
    switch (call.method) {
      case 'getBiometricStatus':
        statusCalls++;
        return <String, dynamic>{
          'available': biometricUsable,
          'enrolled': biometricUsable,
          'enabled': biometricUsable,
        };
      case 'authenticateBiometric':
        authenticateCalls++;
        if (flipOnAuthenticate) biometricUsable = false;
        final current = outcome;
        if (current == 'hang') {
          return Completer<dynamic>().future; // never answers
        }
        if (current == 'success') return true;
        String code;
        if (current == 'busy') {
          code = 'busy';
        } else if (current == 'unavailable') {
          code = 'unavailable';
        } else if (current == 'failed') {
          code = 'auth_failed';
        } else {
          code = 'user_cancel';
        }
        throw PlatformException(code: code);
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lockChannel = MethodChannel('com.bluelock.app/lock');
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late FakeLockChannel fake;
  late AppController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fake = FakeLockChannel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockChannel, fake.handle);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
      if (call.method == 'getBiometricStatus') {
        return <String, dynamic>{
          'available': fake.biometricUsable,
          'enrolled': fake.biometricUsable,
          'enabled': fake.biometricUsable,
        };
      }
      if (call.method == 'authenticateBiometric') {
        // Self-gate path reuses the same fake outcomes.
        fake.authenticateCalls++;
        if (fake.flipOnAuthenticate) fake.biometricUsable = false;
        if (fake.outcome == 'hang') return Completer<dynamic>().future;
        if (fake.outcome == 'success') return true;
        final code = fake.outcome == 'failed' ? 'auth_failed' : fake.outcome;
        throw PlatformException(code: code);
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async => null);
  });

  Future<AppController> makeController() async {
    final storage = AppStorage();
    await storage.init();
    final c = AppController(
      storage: storage,
      native: NativeBridge(),
      services: const AppControllerServices(derive: _testDerive),
    );
    await c.init();
    return c;
  }

  Future<void> bootLock(
    WidgetTester tester,
    AppController controller,
    String packageName,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BlueLockApp(
      controller: controller,
      selfLockHost: false,
    ));
    BlueLockApp.navigatorKey.currentState!.pushNamed('lock/$packageName');
    await tester.pumpAndSettle();
    expect(find.byType(AppLockScreen), findsOneWidget);
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

  TextButton biometricButton(WidgetTester tester) =>
      tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Unlock with biometrics'),
      );

  const unavailableMsg = 'Biometric unlock unavailable. Enter your PIN.';
  const failedMsg = 'Biometric unlock failed. Enter your PIN.';

  group('message/button consistency on the protected-app lock screen', () {
    testWidgets(
        'a transient "busy" refusal never shows the unavailable banner while '
        'the biometric button is still offered', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'busy';
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();

      expect(fake.authenticateCalls, 1,
          reason: 'the auto prompt must not retry in a loop');
      expect(find.text(unavailableMsg), findsNothing,
          reason: 'an available device must never read as "unavailable"');
      expect(find.text(failedMsg), findsOneWidget,
          reason: 'transient refusal reads as a failed attempt');
      expect(
          find.widgetWithText(TextButton, 'Unlock with biometrics'),
          findsOneWidget,
          reason: 'biometrics are still usable, so the button stays');
      expect(biometricButton(tester).onPressed, isNotNull,
          reason: 'and it must be tappable again');
      expect(find.text('Enter your PIN to continue.'), findsOneWidget,
          reason: 'PIN keypad remains the fallback');
    });

    testWidgets(
        'the same applies to an "unavailable" code when a fresh status check '
        'says biometrics still work', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'unavailable';
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();

      expect(find.text(unavailableMsg), findsNothing);
      expect(find.text(failedMsg), findsOneWidget);
      expect(
          find.widgetWithText(TextButton, 'Unlock with biometrics'),
          findsOneWidget);
      expect(biometricButton(tester).onPressed, isNotNull);
    });

    testWidgets(
        'when biometrics really became unusable the banner says unavailable '
        'and the button disappears with it', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'busy';
      fake.flipOnAuthenticate = true; // device state changed mid-prompt
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();

      expect(fake.statusCalls, greaterThanOrEqualTo(2),
          reason: 'a fresh status check must follow every failure');
      expect(find.text(unavailableMsg), findsOneWidget);
      expect(find.text(failedMsg), findsNothing);
      expect(find.widgetWithText(TextButton, 'Unlock with biometrics'),
          findsNothing,
          reason: 'no biometric offer may remain when unavailable is shown');
      expect(find.text('Enter your PIN to continue.'), findsOneWidget,
          reason: 'PIN keypad stays');
    });

    testWidgets(
        'with biometrics unavailable from the start no prompt is launched, '
        'no message is shown and no button is offered', (tester) async {
      fake.biometricUsable = false;
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');
      await tester.pumpAndSettle();

      expect(fake.authenticateCalls, 0);
      expect(find.text(unavailableMsg), findsNothing);
      expect(find.widgetWithText(TextButton, 'Unlock with biometrics'),
          findsNothing);
      expect(find.text('Enter your PIN to continue.'), findsOneWidget);
    });

    testWidgets(
        'cancelling the prompt shows no banner, keeps the button, and never '
        're-prompts on its own', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'user_cancel';
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));

      expect(fake.authenticateCalls, 1,
          reason: 'only the first mount may auto-launch a prompt');
      expect(find.text(unavailableMsg), findsNothing);
      expect(find.text(failedMsg), findsNothing);
      expect(biometricButton(tester).onPressed, isNotNull);
    });

    testWidgets(
        'after a failure the user can tap the button to retry (manual, '
        'never looping)', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'failed';
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();
      expect(find.text(failedMsg), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Unlock with biometrics'));
      await tester.pumpAndSettle();

      expect(fake.authenticateCalls, 2,
          reason: 'a user tap retries exactly once');
      expect(fake.statusCalls, greaterThanOrEqualTo(3),
          reason: 'each failure triggers a fresh status check');
    });

    testWidgets(
        'a platform call that never answers cannot leave the button '
        'disabled (Dart watchdog)', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'hang';
      controller = await makeController();
      await bootLock(tester, controller, 'com.example.instagram');

      await waitFor(tester, () => fake.authenticateCalls == 1);
      expect(biometricButton(tester).onPressed, isNull,
          reason: 'button is held while the prompt round trip is pending');

      await tester.pump(LockSession.biometricCallTimeout +
          const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text(failedMsg), findsOneWidget,
          reason: 'the hang surfaces as a failed attempt, not as silence');
      expect(biometricButton(tester).onPressed, isNotNull,
          reason: 'the button is re-armed after the watchdog');
    });
  });

  group('self lock screen consistency', () {
    testWidgets(
        'a transient refusal shows the failed banner with the button still '
        'offered (never the unavailable contradiction)', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'busy';
      controller = await makeController();

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SelfLockScreen(controller: controller),
      ));

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();

      expect(find.text(unavailableMsg), findsNothing);
      expect(find.text(failedMsg), findsOneWidget);
      expect(
          find.widgetWithText(TextButton, 'Unlock with biometrics'),
          findsOneWidget,
          reason: 'biometrics are still usable, so the button stays');
      expect(biometricButton(tester).onPressed, isNotNull);
      expect(find.text('Enter your PIN to continue.'), findsOneWidget);
    });

    testWidgets(
        'when biometrics are unusable the self gate hides the button next '
        'to the unavailable banner', (tester) async {
      fake.biometricUsable = true;
      fake.outcome = 'unavailable';
      fake.flipOnAuthenticate = true;
      controller = await makeController();

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SelfLockScreen(controller: controller),
      ));

      await waitFor(tester, () => fake.authenticateCalls == 1);
      await tester.pumpAndSettle();

      expect(find.text(unavailableMsg), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Unlock with biometrics'),
          findsNothing);
      expect(find.text('Enter your PIN to continue.'), findsOneWidget);
    });
  });
}
