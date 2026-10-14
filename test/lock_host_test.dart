import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/features/app_lock/presentation/app_lock_screen.dart';
import 'package:blue_lock/features/app_lock/presentation/lock_host_screen.dart';

/// Lock-host lifecycle: the cached engine boots the lock route idle and the
/// native side pushes the protected package over the lock channel. These
/// tests pin the host contract:
///
///  1. Cold boot (package in the initial route) renders the PIN screen.
///  2. Warm idle boot renders no PIN screen until "showLock".
///  3. "showLock" mounts the PIN screen; "clearLock" unmounts it.
///  4. Every showLock remounts (fresh PIN state) even for the same package -
///     the engine is detached between lock activities, so no idle frame can
///     separate two shows of one package.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pkg = 'com.example.someapp';
  const lockChannel = MethodChannel('com.bluelock.app/lock');
  const codec = StandardMethodCodec();

  late AppController controller;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
      if (call.method == 'getAppInfo') {
        return <dynamic, dynamic>{
          'package': call.arguments as String,
          'label': 'Some App',
          'icon':
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
          'isSystem': false,
        };
      }
      return null;
    });
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    controller = AppController(storage: storage, native: NativeBridge());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lockChannel, null);
  });

  Future<void> sendLockChannel(WidgetTester tester, String method,
      [Object? arguments]) async {
    final data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(lockChannel.name, data, (ByteData? _) {});
    await tester.pump();
  }

  testWidgets('cold boot with route package renders the PIN screen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LockHostScreen(controller: controller, initialPackage: pkg),
    ));
    expect(find.byType(AppLockScreen), findsOneWidget);
  });

  testWidgets('warm idle boot renders the placeholder, not the PIN screen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LockHostScreen(controller: controller),
    ));
    expect(find.byType(AppLockScreen), findsNothing);
  });

  testWidgets('showLock mounts the PIN screen and clearLock unmounts it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LockHostScreen(controller: controller),
    ));
    expect(find.byType(AppLockScreen), findsNothing);

    await sendLockChannel(tester, 'showLock', pkg);
    expect(find.byType(AppLockScreen), findsOneWidget);

    await sendLockChannel(tester, 'clearLock');
    expect(find.byType(AppLockScreen), findsNothing);
  });

  testWidgets('repeated showLock remounts with fresh state per session',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LockHostScreen(controller: controller),
    ));

    await sendLockChannel(tester, 'showLock', pkg);
    final first = tester.widget<AppLockScreen>(find.byType(AppLockScreen));
    final firstKey = first.key;
    expect(firstKey, isNotNull);

    await sendLockChannel(tester, 'clearLock');
    await sendLockChannel(tester, 'showLock', pkg);
    final second = tester.widget<AppLockScreen>(find.byType(AppLockScreen));
    expect(second.key, isNotNull);
    // A different key forces a full remount: PIN digits, error banners and
    // the biometric prompt lifecycle cannot leak between lock sessions.
    expect(second.key == firstKey, isFalse);
  });
}
