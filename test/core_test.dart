import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/features/authentication/services/pin_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('storage initializes and tracks defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    expect(storage.onboardingDone, isFalse);
    expect(storage.lockEnabled, isTrue);
    expect(storage.relockTimeoutSeconds, 0);
    expect(storage.lockedPackages, isEmpty);
    expect(await storage.hasPin(), isFalse);
  });

  test('pin create and verify roundtrip', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    final pin = PinService(storage);
    await pin.createPin('1234');
    await pin.loadPinState();
    expect(pin.hasPinSync, isTrue);
    expect(await pin.verifyPin('1234'), isTrue);
    expect(await pin.verifyPin('9999'), isFalse);
  });

  test('controller initializes without native platform', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    final controller = AppController(
      storage: storage,
      native: NativeBridge(),
    );
    await controller.init();
    expect(controller.protectedCount, 0);
    expect(controller.lockEnabled, isTrue);
  });
}
