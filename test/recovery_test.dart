import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/authentication/authentication_type.dart';
import 'package:blue_lock/core/authentication/recovery_code.dart';
import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/features/app_lock/presentation/app_lock_screen.dart';
import 'package:blue_lock/features/authentication/presentation/recovery_screen.dart';
import 'package:blue_lock/features/authentication/services/pin_service.dart';
import 'package:blue_lock/features/authentication/services/recovery_service.dart';
import 'package:blue_lock/features/settings/presentation/settings_screen.dart';

/// Deterministic fast stand-in for PBKDF2; the real derivation is covered by
/// pin_crypto_test / pin_crypto_async_test.
Future<Uint8List> _testDerive(String credential, Uint8List salt) async {
  final units = credential.codeUnits;
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
  final nativeCalls = <String>[];
  final nativeCallLog = <String>[];
  final lockCalls = <String>[];
  var failWrites = false;

  setUp(() {
    secureStore.clear();
    nativeCalls.clear();
    nativeCallLog.clear();
    lockCalls.clear();
    failWrites = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
          nativeCalls.add(call.method);
          nativeCallLog.add('${call.method}|${call.arguments}');
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockChannel, (call) async {
          lockCalls.add(call.method);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          switch (call.method) {
            case 'read':
              return secureStore[args['key']];
            case 'write':
              if (failWrites) {
                throw PlatformException(code: 'write_error');
              }
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

  Future<void> enterDigits(WidgetTester tester, String digits) async {
    for (final digit in digits.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
  }

  /// Pushes the recovery screen over a host route so "Cancel" and the final
  /// pop have somewhere real to return to.
  Future<void> openRecovery(
    WidgetTester tester,
    AppController controller, {
    bool biometricAvailable = false,
    Future<String> Function()? requestBiometric,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RecoveryScreen(
                      controller: controller,
                      biometricAvailable: biometricAvailable,
                      requestBiometric: requestBiometric,
                    ),
                  ),
                ),
                child: const Text('Open recovery'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open recovery'));
    await tester.pumpAndSettle();
  }

  group('recovery code format', () {
    test('generates 16 unambiguous characters grouped for display', () {
      final code = RecoveryCode.generate();
      expect(code.length, RecoveryCode.characters);
      for (final unit in code.codeUnits) {
        expect(
          RecoveryCode.alphabet.codeUnits,
          contains(unit),
          reason: 'only the documented alphabet may be used',
        );
      }
      expect(RecoveryCode.normalize(code), code);
      final formatted = RecoveryCode.format(code);
      expect(formatted, matches(RegExp(r'^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$')));
      expect(RecoveryCode.normalize(formatted.toLowerCase()), code);
      expect(
        RecoveryCode.normalize(formatted.toLowerCase().replaceAll('-', ' ')),
        code,
      );
    });

    test('rejects malformed input instead of silently repairing it', () {
      expect(RecoveryCode.normalize(''), isNull);
      expect(RecoveryCode.normalize('AAAA-AAAA-AAAA-AAA'), isNull);
      expect(RecoveryCode.normalize('AAAA-AAAA-AAAA-AAAAA'), isNull);
      expect(RecoveryCode.normalize('AAAA-AAAA-AAAA-AAA0'), isNull);
      expect(RecoveryCode.normalize('AAAA-AAAA-AAAA-AAAO'), isNull);
    });
  });

  group('RecoveryService', () {
    test(
      'stores only a verifier and verifies formatted, lower-case input',
      () async {
        final storage = AppStorage();
        await storage.init();
        final service = RecoveryService(storage, derive: _testDerive);

        final code = await service.createRecoveryCode();
        expect(await service.hasRecoveryCode(), isTrue);

        final stored = secureStore['recovery_verifier'];
        expect(stored, isNotNull);
        expect(
          stored!.contains(code),
          isFalse,
          reason: 'the plaintext recovery code must never be persisted',
        );
        expect(stored.contains('"salt"'), isTrue);
        expect(stored.contains('"verifier"'), isTrue);

        final formatted = RecoveryCode.format(code)
            .toLowerCase()
            .replaceAll('-', ' ');
        expect((await service.verifyCode(formatted)).isSuccess, isTrue);
        expect(storage.pinFailedAttempts, 0);
      },
    );

    test(
      'wrong codes are rate limited and share the primary lockout',
      () async {
        final storage = AppStorage();
        await storage.init();
        final pinService = PinService(storage, derive: _testDerive);
        await pinService.createCredential(
          type: AuthenticationType.pin4Digit,
          credential: '1234',
        );
        final recovery = RecoveryService(storage, derive: _testDerive);
        await recovery.createRecoveryCode();

        for (var i = 0; i < PinService.maxFailedAttempts - 1; i++) {
          final result = await recovery.verifyCode('AAAA-AAAA-AAAA-AAAA');
          expect(result.status, RecoveryVerificationStatus.incorrect);
        }
        expect(storage.pinFailedAttempts, PinService.maxFailedAttempts - 1);

        final lockedOut = await recovery.verifyCode('AAAA-AAAA-AAAA-AAAA');
        expect(lockedOut.status, RecoveryVerificationStatus.lockedOut);
        expect(lockedOut.lockoutSeconds, greaterThan(0));

        // The same persisted counters also block the primary credential: a
        // recovery lockout cannot be sidestepped by switching methods.
        expect(
          (await pinService.verifyPinDetailed('1234')).isLockedOut,
          isTrue,
        );

        // A new service instance still sees the lockout.
        final reopened = RecoveryService(storage, derive: _testDerive);
        expect(
          (await reopened.verifyCode('AAAA-AAAA-AAAA-AAAA')).isLockedOut,
          isTrue,
        );

        // Expire just the deadline; the correct code is accepted again and the
        // attempt state is cleared.
        await storage.setPinAttemptState(
          failedAttempts: 0,
          lockoutUntilMs: DateTime.now().millisecondsSinceEpoch - 1000,
          lockoutStage: storage.pinLockoutStage,
        );
        final code2 = await recovery.createRecoveryCode();
        expect((await reopened.verifyCode(code2)).isSuccess, isTrue);
        expect(storage.pinFailedAttempts, 0);
      },
    );

    test('a malformed code consumes an attempt but is never hashed as a '
        'different credential', () async {
      final storage = AppStorage();
      await storage.init();
      final recovery = RecoveryService(storage, derive: _testDerive);
      await recovery.createRecoveryCode();

      final result = await recovery.verifyCode('short');
      expect(result.status, RecoveryVerificationStatus.incorrect);
      expect(storage.pinFailedAttempts, 1);
    });

    test('an install without a recovery verifier is reported as not '
        'configured and is never treated as a reset', () async {
      final storage = AppStorage();
      await storage.init();
      final pinService = PinService(storage, derive: _testDerive);
      await pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      final recovery = RecoveryService(storage, derive: _testDerive);

      expect(await recovery.hasRecoveryCode(), isFalse);
      final result = await recovery.verifyCode('AAAA-AAAA-AAAA-AAAA');
      expect(result.status, RecoveryVerificationStatus.notConfigured);
      expect(
        storage.pinFailedAttempts,
        0,
        reason: 'no attempt is consumed when there is nothing to verify',
      );
      expect((await pinService.verifyPinDetailed('1234')).isSuccess, isTrue);
    });

    test(
      'a failed verifier write keeps the previous recovery code valid',
      () async {
        final storage = AppStorage();
        await storage.init();
        final recovery = RecoveryService(storage, derive: _testDerive);
        final oldCode = await recovery.createRecoveryCode();

        failWrites = true;
        await expectLater(recovery.createRecoveryCode(), throwsA(anything));
        failWrites = false;

        expect(await recovery.hasRecoveryCode(), isTrue);
        expect((await recovery.verifyCode(oldCode)).isSuccess, isTrue);
      },
    );
  });

  group('recovery does not reset state', () {
    test(
      'a failed save leaves the credential and every setting untouched',
      () async {
        final controller = await makeController();
        await controller.pinService.createCredential(
          type: AuthenticationType.pin4Digit,
          credential: '1234',
        );
        await controller.setPackageLocked('com.example.victim', true);
        await controller.setRelockTimeout(30);

        failWrites = true;
        await expectLater(
          controller.completeRecovery(
            type: AuthenticationType.pin6Digit,
            credential: '654321',
          ),
          throwsA(anything),
        );
        failWrites = false;

        expect(controller.authType, AuthenticationType.pin4Digit);
        expect(
          (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
          isTrue,
        );
        expect(
          (await controller.pinService.verifyPinDetailed('654321')).isSuccess,
          isFalse,
        );
        expect(controller.isLocked('com.example.victim'), isTrue);
        expect(controller.relockTimeoutSeconds, 30);
        expect(
          nativeCalls.contains('lockAllSessions'),
          isFalse,
          reason: 'nothing may be revoked when the replacement failed',
        );
      },
    );

    testWidgets('the no-factor card explains the limitation and offers no '
        'in-app bypass', (tester) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.setPackageLocked('com.example.victim', true);

      await openRecovery(tester, controller);

      expect(find.text("Verify it's you"), findsOneWidget);
      expect(find.text('No recovery method is configured'), findsOneWidget);
      expect(find.textContaining("clear Blue Lock's app data"), findsWidgets);
      expect(find.textContaining('platform-enforced'), findsWidgets);
      expect(find.textContaining('Reset'), findsNothing);
      expect(controller.selfUnlocked, isFalse);

      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryScreen), findsNothing);
      expect(controller.hasPin, isTrue);
      expect(controller.isLocked('com.example.victim'), isTrue);
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isTrue,
      );
    });

    testWidgets(
      'Forgot PIN opens verified recovery without clearing the lock',
      (tester) async {
        final controller = await makeController();
        await controller.pinService.createCredential(
          type: AuthenticationType.pin4Digit,
          credential: '1234',
        );
        await controller.setPackageLocked('com.example.victim', true);

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: AppLockScreen(
              packageName: 'com.example.victim',
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Forgot PIN?'));
        await tester.pumpAndSettle();
        expect(find.byType(RecoveryScreen), findsOneWidget);
        expect(find.text("Verify it's you"), findsOneWidget);

        // Backing out changes nothing.
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(RecoveryScreen), findsNothing);
        expect(controller.hasPin, isTrue);
        expect(controller.isLocked('com.example.victim'), isTrue);
        expect(
          (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
          isTrue,
        );
        expect(nativeCalls, isNot(contains('resetProtection')));
      },
    );
  });

  group('verified recovery', () {
    testWidgets('the recovery code replaces the credential and preserves '
        'protected apps and settings', (tester) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.setPackageLocked('com.example.victim', true);
      await controller.setRelockTimeout(60);
      await controller.setBiometricEnabled(false);
      final code = await controller.recoveryService.createRecoveryCode();
      nativeCalls.clear();
      nativeCallLog.clear();

      await openRecovery(tester, controller);
      await tester.tap(find.text('Use recovery code'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        RecoveryCode.format(code).toLowerCase(),
      );
      await tester.pump();
      await tester.tap(find.text('Verify code'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a new lock type'), findsOneWidget);

      await tester.tap(find.text('Six-Digit PIN'));
      await tester.pumpAndSettle();
      expect(find.text('Set up your Six-Digit PIN'), findsOneWidget);

      await enterDigits(tester, '654321');
      await tester.pumpAndSettle();
      expect(find.text('Confirm your 6-digit PIN'), findsOneWidget);
      await enterDigits(tester, '654321');
      await tester.pumpAndSettle();

      expect(
        find.byType(RecoveryScreen),
        findsNothing,
        reason: 'a successful recovery returns to the lock screen',
      );
      expect(controller.authType, AuthenticationType.pin6Digit);
      expect(
        (await controller.pinService.verifyPinDetailed('654321')).isSuccess,
        isTrue,
      );
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isFalse,
      );
      expect(
        controller.isLocked('com.example.victim'),
        isTrue,
        reason: 'recovery must not clear the protected-app list',
      );
      expect(controller.relockTimeoutSeconds, 60);
      expect(
        controller.storage.biometricEnabled,
        isFalse,
        reason: 'the biometric preference is a setting, not part of the lock',
      );
      expect(
        nativeCalls,
        contains('lockAllSessions'),
        reason: 'sessions granted under the forgotten credential must die',
      );
      expect(
        nativeCallLog.any(
          (call) =>
              call.startsWith('setLockEnabled|') ||
              call.startsWith('setProtectedPackages|'),
        ),
        isFalse,
        reason: 'recovery must not stop monitoring or rewrite protection',
      );
      expect(
        lockCalls,
        isNot(contains('unlock')),
        reason:
            'no protected app may be opened before the new credential saves',
      );
      expect(
        await controller.recoveryService.hasRecoveryCode(),
        isTrue,
        reason: 'the recovery verifier is independent of the credential',
      );
    });

    testWidgets('a wrong recovery code shows an error and never reaches the '
        'new-credential step', (tester) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.recoveryService.createRecoveryCode();

      await openRecovery(tester, controller);
      await tester.tap(find.text('Use recovery code'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'AAAA-AAAA-AAAA-AAAA');
      await tester.pump();
      await tester.tap(find.text('Verify code'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect recovery code. Try again.'), findsOneWidget);
      expect(find.text('Choose a new lock type'), findsNothing);
      expect(controller.authType, AuthenticationType.pin4Digit);
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isTrue,
      );
    });

    testWidgets('enrolled biometrics authorise recovery without a code', (
      tester,
    ) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.setPackageLocked('com.example.victim', true);
      await controller.recoveryService.createRecoveryCode();
      var prompts = 0;

      await openRecovery(
        tester,
        controller,
        biometricAvailable: true,
        requestBiometric: () async {
          prompts++;
          return 'success';
        },
      );

      await tester.tap(find.text('Recover with biometrics'));
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(find.text('Choose a new lock type'), findsOneWidget);

      await tester.tap(find.text('Password'));
      await tester.pumpAndSettle();
      expect(find.text('Set up your Password'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'new pass 1');
      await tester.enterText(find.byType(TextField).at(1), 'new pass 1');
      await tester.pump();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(controller.authType, AuthenticationType.password);
      expect(
        (await controller.pinService.verifyPinDetailed('new pass 1')).isSuccess,
        isTrue,
      );
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isFalse,
      );
      expect(controller.isLocked('com.example.victim'), isTrue);
    });

    testWidgets('cancelling the biometric prompt leaves the lock unchanged', (
      tester,
    ) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );

      await openRecovery(
        tester,
        controller,
        biometricAvailable: true,
        requestBiometric: () async => 'user_cancel',
      );

      await tester.tap(find.text('Recover with biometrics'));
      await tester.pumpAndSettle();
      expect(find.text("Verify it's you"), findsOneWidget);
      expect(find.text('Choose a new lock type'), findsNothing);
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isTrue,
      );
    });

    testWidgets('a failed biometric attempt leaves the lock and the code '
        'fallback intact', (tester) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.setPackageLocked('com.example.victim', true);
      await controller.recoveryService.createRecoveryCode();

      await openRecovery(
        tester,
        controller,
        biometricAvailable: true,
        requestBiometric: () async => 'failed',
      );

      await tester.tap(find.text('Recover with biometrics'));
      await tester.pumpAndSettle();
      expect(
        find.text('Biometric recovery failed. Use your recovery code.'),
        findsOneWidget,
      );
      expect(find.text("Verify it's you"), findsOneWidget);
      expect(find.text('Choose a new lock type'), findsNothing);
      expect(find.text('Use recovery code'), findsOneWidget);
      expect(controller.isLocked('com.example.victim'), isTrue);
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isTrue,
      );
      expect(nativeCalls, isNot(contains('lockAllSessions')));
    });

    testWidgets('an authorised recovery abandoned before saving opens '
        'nothing', (tester) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.setPackageLocked('com.example.victim', true);
      final code = await controller.recoveryService.createRecoveryCode();

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockScreen(
            packageName: 'com.example.victim',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Forgot PIN?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use recovery code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), RecoveryCode.format(code));
      await tester.pump();
      await tester.tap(find.text('Verify code'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a new lock type'), findsOneWidget);

      // The factor was valid, but the credential has not been replaced yet.
      // Backing out must not unlock the protected app.
      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryScreen), findsNothing);
      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(lockCalls, isNot(contains('unlock')));
      expect(controller.isLocked('com.example.victim'), isTrue);
      expect(controller.authType, AuthenticationType.pin4Digit);
      expect(
        (await controller.pinService.verifyPinDetailed('1234')).isSuccess,
        isTrue,
      );
    });

    testWidgets('biometric unlock still works with the recovered credential', (
      tester,
    ) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );
      await controller.setPackageLocked('com.example.victim', true);
      await controller.recoveryService.createRecoveryCode();
      await controller.completeRecovery(
        type: AuthenticationType.pin6Digit,
        credential: '654321',
      );
      expect(
        (await controller.pinService.verifyPinDetailed('654321')).isSuccess,
        isTrue,
      );

      var unlocks = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(lockChannel, (call) async {
            lockCalls.add(call.method);
            switch (call.method) {
              case 'getBiometricStatus':
                return {'available': true, 'enrolled': true, 'enabled': true};
              case 'authenticateBiometric':
                return true;
            }
            return null;
          });

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AppLockScreen(
            packageName: 'com.example.victim',
            controller: controller,
            nativeLock: true,
            onUnlocked: () => unlocks++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(unlocks, 1);
      expect(lockCalls, contains('authenticateBiometric'));
      expect(lockCalls, contains('unlock'));
    });
  });

  group('settings recovery setup', () {
    testWidgets('an existing install can generate a code and keeps only its '
        'verifier', (tester) async {
      final controller = await makeController();
      await controller.pinService.createCredential(
        type: AuthenticationType.pin4Digit,
        credential: '1234',
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Not set up - add a way back into Blue Lock'),
        findsOneWidget,
      );
      await tester.tap(find.text('Recovery code'));
      await tester.pumpAndSettle();

      expect(find.text('Save your recovery code'), findsOneWidget);
      final pattern = RegExp(r'^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$');
      final displayed = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .firstWhere(pattern.hasMatch);
      expect(secureStore['recovery_verifier']!.contains(displayed), isFalse);
      expect(await controller.recoveryService.hasRecoveryCode(), isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text('Configured - use it if you forget your lock'),
        findsOneWidget,
      );
    });
  });
}
