import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/core/utils/pin_crypto.dart';
import 'package:blue_lock/features/authentication/services/pin_service.dart';

/// Confirms the persisted PIN throttling policy:
///  - five wrong attempts trigger a 30 s lockout;
///  - lockout state survives a new storage/service instance (process restart);
///  - a correct PIN is refused while locked out;
///  - expiry returns to normal verification;
///  - successive lockouts back off (30 s -> 1 min -> 2 min -> 5 min, capped);
///  - a successful PIN and a new PIN both clear the counter.
Future<Uint8List> _testDerive(String pin, Uint8List salt) async =>
    PinCrypto.deriveVerifier(pin, salt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};

  setUp(() {
    secureStore.clear();
    SharedPreferences.setMockInitialValues({});
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

  Future<AppStorage> makeStorage() async {
    final storage = AppStorage();
    await storage.init();
    return storage;
  }

  Future<PinService> makeService({AppStorage? storage}) async {
    final s = storage ?? await makeStorage();
    final service = PinService(s, derive: _testDerive);
    await service.createPin('1234');
    return service;
  }

  test('five wrong attempts lock PIN verification for 30 seconds', () async {
    final service = await makeService();

    for (var i = 1; i < PinService.maxFailedAttempts; i++) {
      final result = await service.verifyPinDetailed('0000');
      expect(result.isSuccess, isFalse);
      expect(result.isLockedOut, isFalse);
      expect(result.remainingAttempts, PinService.maxFailedAttempts - i);
    }

    final fifth = await service.verifyPinDetailed('0000');
    expect(fifth.isLockedOut, isTrue);
    expect(fifth.lockoutSeconds, 30);
    expect(fifth.message, contains('30 seconds'));
  });

  test('lockout cannot be bypassed by creating a new storage/service',
      () async {
    final storage = await makeStorage();
    final service = await makeService(storage: storage);
    for (var i = 0; i < PinService.maxFailedAttempts; i++) {
      await service.verifyPinDetailed('0000');
    }

    // Simulates the lock activity being recreated or the process restarted:
    // same persisted preferences, brand-new objects.
    final restarted = PinService(storage, derive: _testDerive);
    final correct = await restarted.verifyPinDetailed('1234');
    expect(correct.isSuccess, isFalse);
    expect(correct.isLockedOut, isTrue,
        reason: 'the correct PIN must not bypass an active lockout');
  });

  test('lockout expiry allows verification and success resets the counter',
      () async {
    final storage = await makeStorage();
    final service = await makeService(storage: storage);
    for (var i = 0; i < PinService.maxFailedAttempts; i++) {
      await service.verifyPinDetailed('0000');
    }
    expect(await service.lockoutRemainingSeconds(), greaterThan(0));

    // Fast-forward past the deadline without sleeping 30 seconds.
    await storage.setPinAttemptState(
      failedAttempts: 0,
      lockoutUntilMs: DateTime.now().millisecondsSinceEpoch - 1,
      lockoutStage: storage.pinLockoutStage,
    );

    expect(await service.lockoutRemainingSeconds(), 0);
    final ok = await service.verifyPinDetailed('1234');
    expect(ok.isSuccess, isTrue);
    expect(storage.pinFailedAttempts, 0);
    expect(storage.pinLockoutStage, 0);
    expect(storage.pinLockoutUntilMs, 0);
  });

  test('successful verification clears earlier failures', () async {
    final service = await makeService();
    await service.verifyPinDetailed('0000');
    await service.verifyPinDetailed('0000');
    expect((await service.verifyPinDetailed('1234')).isSuccess, isTrue);

    final next = await service.verifyPinDetailed('0000');
    expect(next.remainingAttempts, PinService.maxFailedAttempts - 1,
        reason: 'a success must reset the attempt counter');
  });

  test('successive lockouts back off up to the five-minute cap', () async {
    final storage = await makeStorage();
    final service = await makeService(storage: storage);

    final expected = <int>[30, 60, 120, 300, 300];
    for (final seconds in expected) {
      for (var i = 0; i < PinService.maxFailedAttempts; i++) {
        final result = await service.verifyPinDetailed('0000');
        if (i < PinService.maxFailedAttempts - 1) {
          expect(result.isLockedOut, isFalse);
        } else {
          expect(result.isLockedOut, isTrue);
          expect(result.lockoutSeconds, seconds);
        }
      }
      // Skip the current lockout window.
      await storage.setPinAttemptState(
        failedAttempts: 0,
        lockoutUntilMs: DateTime.now().millisecondsSinceEpoch - 1,
        lockoutStage: storage.pinLockoutStage,
      );
    }
  });

  test('a newly created PIN clears an active lockout', () async {
    final storage = await makeStorage();
    final service = await makeService(storage: storage);
    for (var i = 0; i < PinService.maxFailedAttempts; i++) {
      await service.verifyPinDetailed('0000');
    }
    expect(await service.lockoutRemainingSeconds(), greaterThan(0));

    await service.createPin('4321');
    expect(await service.lockoutRemainingSeconds(), 0);
    expect((await service.verifyPinDetailed('4321')).isSuccess, isTrue);
  });

  test('missing verifier reports setup needed instead of a wrong PIN', () async {
    // Simulates a device migration that copied preferences but not the
    // device-bound secure storage holding the PIN verifier.
    final storage = await makeStorage();
    final service = PinService(storage, derive: _testDerive);

    final result = await service.verifyPinDetailed('1234');
    expect(result.status, PinVerificationStatus.noPin);
    expect(result.isSuccess, isFalse);
    expect(result.isLockedOut, isFalse);
    expect(result.message, contains('No PIN is set up'));
    expect(storage.pinFailedAttempts, 0,
        reason: 'a missing verifier must not consume an attempt');
    expect(storage.pinLockoutUntilMs, 0);
  });
}
