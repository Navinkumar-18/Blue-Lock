import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/app.dart';
import 'package:blue_lock/core/authentication/authentication_type.dart';
import 'package:blue_lock/core/authentication/credential_rules.dart';
import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/core/utils/pin_crypto.dart';
import 'package:blue_lock/features/app_lock/presentation/app_lock_screen.dart';
import 'package:blue_lock/features/app_lock/presentation/self_lock_screen.dart';
import 'package:blue_lock/features/authentication/presentation/change_lock_type_screen.dart';
import 'package:blue_lock/features/authentication/services/pin_service.dart';
import 'package:blue_lock/features/dashboard/presentation/home_shell.dart';
import 'package:blue_lock/shared/widgets/pattern_lock_panel.dart';

/// Deterministic, fast stand-in for PBKDF2. Production derivation is covered
/// by pin_crypto_test / pin_crypto_async_test; these tests exercise the
/// multi-method storage and UI flows without paying 120k iterations per tap.
Future<Uint8List> _testDerive(String credential, Uint8List salt) async {
  final units = utf8.encode(credential);
  final out = Uint8List(32);
  for (var i = 0; i < out.length; i++) {
    final unit = units.isEmpty ? 0 : units[i % units.length];
    out[i] = (salt[i % salt.length] ^ unit ^ (i * 31)) & 0xFF;
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const lockChannel = MethodChannel('com.bluelock.app/lock');
  final secureStore = <String, String>{};

  setUp(() {
    secureStore.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async => null);
    // The lock screen records unlocks on its own channel; without a handler
    // the method future never settles inside the fake-async test zone and the
    // success callback would never run.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockChannel, (call) async => null);
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

  Future<AppController> makeController() async {
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

  Future<void> boot(WidgetTester tester, AppController controller) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BlueLockApp(controller: controller));
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() isDone, {
    int maxIterations = 120,
  }) async {
    for (var i = 0; i < maxIterations && !isDone(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> enterDigits(WidgetTester tester, String digits) async {
    for (final digit in digits.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
  }

  Future<void> drawPattern(WidgetTester tester, List<int> dots) async {
    final gesture = find
        .descendant(
          of: find.byType(PatternLockPanel),
          matching: find.byType(GestureDetector),
        )
        .first;
    final rect = tester.getRect(gesture);
    final padding = rect.width * 0.1;
    final step = (rect.width - padding * 2) / 2;
    for (final dot in dots) {
      final offset = Offset(
        rect.left + padding + (dot % 3) * step,
        rect.top + padding + (dot ~/ 3) * step,
      );
      await tester.tapAt(offset);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpLockScreen(
    WidgetTester tester,
    AppController controller, {
    required VoidCallback onUnlocked,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockScreen(
          packageName: 'com.example.victim',
          controller: controller,
          onUnlocked: onUnlocked,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('authentication type persistence', () {
    test(
      'every storage value round-trips; unknown or missing is 4-digit PIN',
      () {
        for (final type in AuthenticationType.values) {
          expect(AuthenticationType.fromStorage(type.storageValue), type);
          expect(AuthenticationType.tryParse(type.storageValue), type);
        }
        expect(
          AuthenticationType.fromStorage(null),
          AuthenticationType.pin4Digit,
        );
        expect(
          AuthenticationType.fromStorage(''),
          AuthenticationType.pin4Digit,
        );
        expect(
          AuthenticationType.fromStorage('face_id'),
          AuthenticationType.pin4Digit,
        );
        expect(AuthenticationType.tryParse('face_id'), isNull);
      },
    );
  });

  group('credential rules', () {
    test('six-digit PIN requires exactly six ASCII digits', () {
      expect(
        CredentialRules.validate(AuthenticationType.pin6Digit, '123456'),
        isNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.pin6Digit, '12345'),
        isNotNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.pin6Digit, '1234567'),
        isNotNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.pin6Digit, '12345a'),
        isNotNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.pin4Digit, '123456'),
        isNotNull,
      );
    });

    test(
      'patterns need at least four distinct dots and decode canonically',
      () {
        final encoded = CredentialRules.encodePattern([0, 1, 2, 5]);
        expect(encoded, 'pattern:v1:0-1-2-5');
        expect(CredentialRules.decodePattern(encoded), [0, 1, 2, 5]);
        expect(
          CredentialRules.validate(AuthenticationType.pattern, encoded),
          isNull,
        );

        expect(
          () => CredentialRules.encodePattern([0, 1, 2]),
          throwsArgumentError,
        );
        expect(
          () => CredentialRules.encodePattern([0, 1, 1, 2]),
          throwsArgumentError,
        );
        expect(
          () => CredentialRules.encodePattern([0, 1, 2, 9]),
          throwsArgumentError,
        );
        expect(CredentialRules.decodePattern('pattern:v1:0-1-2'), isNull);
        expect(CredentialRules.decodePattern('pattern:v1:0-1-1-2'), isNull);
      },
    );

    test('passwords preserve interior and surrounding spaces but reject '
        'whitespace-only input', () {
      const password = ' correct horse 9 ';
      expect(
        CredentialRules.validate(AuthenticationType.password, password),
        isNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.password, '    '),
        isNotNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.password, 'abc'),
        isNotNull,
      );
      final maxLength = List.filled(256, 'a').join();
      expect(
        CredentialRules.validate(AuthenticationType.password, maxLength),
        isNull,
      );
      expect(
        CredentialRules.validate(AuthenticationType.password, '${maxLength}a'),
        isNotNull,
      );
    });
  });

  group('PinService', () {
    test('creates and verifies every authentication type', () async {
      final cases = <AuthenticationType, String>{
        AuthenticationType.pin4Digit: '1234',
        AuthenticationType.pin6Digit: '654321',
        AuthenticationType.pattern: CredentialRules.encodePattern([
          0,
          1,
          2,
          5,
          8,
        ]),
        AuthenticationType.password: 'Tr0ub4dor & 3',
      };
      for (final entry in cases.entries) {
        secureStore.clear();
        SharedPreferences.setMockInitialValues({});
        final storage = AppStorage();
        await storage.init();
        final service = PinService(storage, derive: _testDerive);

        await service.createCredential(
          type: entry.key,
          credential: entry.value,
        );
        expect(service.hasPinSync, isTrue);
        expect(service.authType, entry.key);

        final reopened = PinService(storage, derive: _testDerive);
        await reopened.loadPinState();
        expect(
          reopened.authType,
          entry.key,
          reason: '${entry.key.storageValue} must survive a restart',
        );
        expect(
          (await reopened.verifyPinDetailed(entry.value)).isSuccess,
          isTrue,
        );

        final wrong = entry.key == AuthenticationType.pattern
            ? CredentialRules.encodePattern([0, 1, 2, 6, 8])
            : '${entry.value}wrong';
        expect(
          (await reopened.verifyPinDetailed(wrong)).isSuccess,
          isFalse,
          reason: '${entry.key.storageValue} must reject a wrong value',
        );
      }
    });

    test('legacy salt + raw verifier migrates unchanged and defaults to '
        'a four-digit PIN', () async {
      final salt = PinCrypto.generateSalt();
      final verifier = await _testDerive('1234', salt);
      secureStore['pin_salt'] = PinCrypto.saltToBase64(salt);
      secureStore['pin_verifier'] = PinCrypto.verifierToBase64(verifier);

      final storage = AppStorage();
      await storage.init();
      final before = await storage.readCredential();
      expect(before, isNotNull);
      expect(before!.isLegacy, isTrue);
      expect(before.type, AuthenticationType.pin4Digit);
      expect(before.saltB64, PinCrypto.saltToBase64(salt));
      expect(before.verifierB64, PinCrypto.verifierToBase64(verifier));

      final service = PinService(storage, derive: _testDerive);
      await service.loadPinState();
      expect(service.authType, AuthenticationType.pin4Digit);
      expect((await service.verifyPinDetailed('1234')).isSuccess, isTrue);

      // Migration copies the same bytes; it must not re-hash or change type.
      final migrated = await storage.readCredential();
      expect(migrated!.isLegacy, isFalse);
      expect(migrated.type, AuthenticationType.pin4Digit);
      expect(migrated.saltB64, before.saltB64);
      expect(migrated.verifierB64, before.verifierB64);
      expect(secureStore['pin_verifier']!.contains('"v":2'), isTrue);
      expect(secureStore['pin_verifier']!.contains('1234'), isFalse);
    });

    test('an explicit legacy type key is honoured during migration', () async {
      final salt = PinCrypto.generateSalt();
      final verifier = await _testDerive('654321', salt);
      secureStore['pin_salt'] = PinCrypto.saltToBase64(salt);
      secureStore['pin_verifier'] = PinCrypto.verifierToBase64(verifier);
      secureStore['auth_type'] = AuthenticationType.pin6Digit.storageValue;

      final storage = AppStorage();
      await storage.init();
      final service = PinService(storage, derive: _testDerive);
      await service.loadPinState();
      expect(service.authType, AuthenticationType.pin6Digit);
      expect((await service.verifyPinDetailed('654321')).isSuccess, isTrue);
    });

    test('changeCredential rejects a wrong current value and keeps the old '
        'credential working', () async {
      final storage = AppStorage();
      await storage.init();
      final service = PinService(storage, derive: _testDerive);
      await service.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );

      await expectLater(
        service.changeCredential(
          currentCredential: '9999',
          newType: AuthenticationType.pin6Digit,
          newCredential: '654321',
        ),
        throwsA(isA<PinException>()),
      );
      expect(service.authType, AuthenticationType.pin4Digit);
      expect((await service.verifyPinDetailed('1234')).isSuccess, isTrue);
      expect((await service.verifyPinDetailed('654321')).isSuccess, isFalse);
    });

    test('changeCredential rejects an identical credential when the type is '
        'unchanged', () async {
      final storage = AppStorage();
      await storage.init();
      final service = PinService(storage, derive: _testDerive);
      await service.createCredential(
        type: AuthenticationType.pin6Digit,
        credential: '654321',
      );

      await expectLater(
        service.changeCredential(
          currentCredential: '654321',
          newType: AuthenticationType.pin6Digit,
          newCredential: '654321',
        ),
        throwsA(isA<PinException>()),
      );
      expect((await service.verifyPinDetailed('654321')).isSuccess, isTrue);
    });

    test(
      'changeCredential can switch method and the new value is required',
      () async {
        final storage = AppStorage();
        await storage.init();
        final service = PinService(storage, derive: _testDerive);
        await service.createCredential(
          type: AuthenticationType.pin4Digit,
          credential: '1234',
        );

        await service.changeCredential(
          currentCredential: '1234',
          newType: AuthenticationType.password,
          newCredential: 'new password 1',
        );

        expect(service.authType, AuthenticationType.password);
        final reopened = PinService(storage, derive: _testDerive);
        await reopened.loadPinState();
        expect(reopened.authType, AuthenticationType.password);
        expect(
          (await reopened.verifyPinDetailed('new password 1')).isSuccess,
          isTrue,
        );
        expect((await reopened.verifyPinDetailed('1234')).isSuccess, isFalse);
      },
    );

    test('a persisted lockout is shared by the next service instance and '
        'refuses even the correct credential', () async {
      final storage = AppStorage();
      await storage.init();
      final service = PinService(storage, derive: _testDerive);
      await service.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );

      for (var i = 0; i < PinService.maxFailedAttempts; i++) {
        await service.verifyPinDetailed('0000');
      }
      expect((await service.verifyPinDetailed('1234')).isLockedOut, isTrue);

      final reopened = PinService(storage, derive: _testDerive);
      await reopened.loadPinState();
      expect(
        (await reopened.verifyPinDetailed('1234')).isLockedOut,
        isTrue,
        reason: 'restarting must not clear the persisted lockout',
      );

      // Expire just the deadline, keeping the backoff stage: the correct value
      // is accepted again and the attempt counters are cleared.
      await storage.setPinAttemptState(
        failedAttempts: 0,
        lockoutUntilMs:
            DateTime.now().millisecondsSinceEpoch -
            const Duration(seconds: 1).inMilliseconds,
        lockoutStage: storage.pinLockoutStage,
      );
      expect((await reopened.verifyPinDetailed('1234')).isSuccess, isTrue);
      expect(storage.pinFailedAttempts, 0);
    });
  });

  group('widget flows', () {
    testWidgets('six-digit PIN onboarding reaches the recovery step and home', (
      tester,
    ) async {
      final controller = await makeController();
      await boot(tester, controller);

      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Six-Digit PIN'));
      await tester.pumpAndSettle();
      expect(find.text('Create your 6-digit PIN'), findsOneWidget);

      await enterDigits(tester, '123456');
      await tester.pumpAndSettle();
      expect(find.text('Confirm your 6-digit PIN'), findsOneWidget);

      await enterDigits(tester, '123456');
      await waitFor(
        tester,
        () => find.text('Save your recovery code').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('Save your recovery code'), findsOneWidget);

      await tester.tap(find.text("I've saved my recovery code"));
      await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
      await tester.pumpAndSettle();

      expect(find.byType(HomeShell), findsOneWidget);
      expect(controller.authType, AuthenticationType.pin6Digit);
      expect(controller.hasPin, isTrue);
      expect(
        (await controller.pinService.verifyPinDetailed('123456')).isSuccess,
        isTrue,
      );
    });

    testWidgets('six-digit self-lock screen accepts only the six-digit PIN', (
      tester,
    ) async {
      final controller = await makeController();
      await controller.createCredential(
        type: AuthenticationType.pin6Digit,
        credential: '654321',
      );
      await controller.markOnboardingDone();

      await boot(tester, controller);
      expect(find.byType(SelfLockScreen), findsOneWidget);
      expect(find.text('Enter your PIN to continue.'), findsOneWidget);

      await enterDigits(tester, '65432');
      await tester.pumpAndSettle();
      expect(
        find.byType(HomeShell),
        findsNothing,
        reason: 'five digits must not submit',
      );

      await tester.tap(find.text('1'));
      await tester.pumpAndSettle();
      await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(
        find.byType(HomeShell),
        findsOneWidget,
        reason: 'the 6-digit PIN must open the self gate',
      );
    });

    testWidgets('protected-app screen accepts a six-digit PIN', (tester) async {
      final controller = await makeController();
      await controller.createCredential(
        type: AuthenticationType.pin6Digit,
        credential: '654321',
      );
      var unlocked = false;

      await pumpLockScreen(
        tester,
        controller,
        onUnlocked: () => unlocked = true,
      );
      await enterDigits(tester, '000000');
      await tester.pumpAndSettle();
      expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
      expect(unlocked, isFalse);

      await enterDigits(tester, '654321');
      await tester.pumpAndSettle();
      expect(unlocked, isTrue);
    });

    testWidgets('pattern lock screen draws a pattern and rejects a wrong one', (
      tester,
    ) async {
      final controller = await makeController();
      const pattern = [0, 1, 2, 5];
      await controller.createCredential(
        type: AuthenticationType.pattern,
        credential: CredentialRules.encodePattern(pattern),
      );
      var unlocked = false;

      await pumpLockScreen(
        tester,
        controller,
        onUnlocked: () => unlocked = true,
      );
      expect(find.text('Draw your pattern to continue.'), findsOneWidget);
      expect(find.text('Forgot pattern?'), findsOneWidget);

      await drawPattern(tester, const [0, 3, 6, 7]);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect pattern. Try again.'), findsOneWidget);
      expect(unlocked, isFalse);

      await drawPattern(tester, pattern);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(unlocked, isTrue);
    });

    testWidgets('password lock screen handles a wrong and the right password', (
      tester,
    ) async {
      final controller = await makeController();
      await controller.createCredential(
        type: AuthenticationType.password,
        credential: 'Correct horse 9',
      );
      var unlocked = false;

      await pumpLockScreen(
        tester,
        controller,
        onUnlocked: () => unlocked = true,
      );
      expect(find.text('Enter your password to continue.'), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'wrong password');
      await tester.pump();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect password. Try again.'), findsOneWidget);
      expect(unlocked, isFalse);

      await tester.enterText(find.byType(TextField), 'Correct horse 9');
      await tester.pump();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(unlocked, isTrue);
    });

    testWidgets(
      'Change Lock Type verifies the current method and replaces it',
      (tester) async {
        final controller = await makeController();
        await controller.createCredential(
          type: AuthenticationType.pin4Digit,
          credential: '1234',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ChangeLockTypeScreen(controller: controller),
                      ),
                    ),
                    child: const Text('Open change'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open change'));
        await tester.pumpAndSettle();

        expect(find.text('Enter current PIN'), findsOneWidget);
        await enterDigits(tester, '1234');
        await tester.pumpAndSettle();
        expect(find.text('Choose your new lock type'), findsOneWidget);

        await tester.tap(find.text('Six-Digit PIN'));
        await tester.pumpAndSettle();
        expect(find.text('Set up your Six-Digit PIN'), findsOneWidget);

        await enterDigits(tester, '654321');
        await tester.pumpAndSettle();
        expect(find.text('Confirm your 6-digit PIN'), findsOneWidget);
        await enterDigits(tester, '654321');
        await tester.pumpAndSettle();

        expect(controller.authType, AuthenticationType.pin6Digit);
        expect(
          (await controller.pinService.verifyPinDetailed('654321')).isSuccess,
          isTrue,
        );
        expect(
          (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
          isFalse,
        );
      },
    );

    testWidgets('lock screen renders without overflow on a narrow device', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = await makeController();

      await tester.pumpWidget(
        MaterialApp(
          home: AppLockScreen(
            packageName: 'com.example.victim',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // No analyze/log overflow errors are raised by pumpAndSettle: the
      // reusable buttons and credential panel must fit a 320dp device.
      expect(find.text('App Locked'), findsOneWidget);
    });
  });
}
