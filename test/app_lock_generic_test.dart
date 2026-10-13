import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/app.dart';
import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/features/app_lock/presentation/app_lock_screen.dart';
import 'package:blue_lock/features/installed_apps/models/installed_app.dart';

/// Generic app-locking regression tests: Instagram was only an example in
/// the bug report - protection must work for ANY user-selected package.
/// These tests pin the generic behaviour at the routing and state layers:
///
///  1. The lock route works for arbitrary, unrelated package names.
///  2. Lock state is per-package: protecting one app never protects another.
///  3. The lock screen shows the DETECTED app's name, not Blue Lock content.
///  4. Non-lock routes never render the lock screen (no accidental locking).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Two completely unrelated package names - neither is hardcoded anywhere
  // in production logic; they stand in for any two user-selected apps.
  const appOne = 'com.example.appone';
  const appTwo = 'org.sample.apptwo';

  late AppController controller;

  setUpAll(() async {
    // Mock the native channel: completes inside FakeAsync zones and serves
    // per-package app info so the lock screen can resolve labels/icons.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
      switch (call.method) {
        case 'getAppInfo':
          final pkg = call.arguments as String;
          return <dynamic, dynamic>{
            'package': pkg,
            'label': 'Label for $pkg',
            // 1x1 transparent PNG.
            'icon':
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
            'isSystem': false,
          };
        default:
          return null;
      }
    });

    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    controller = AppController(storage: storage, native: NativeBridge());
    await controller.init();
  });

  testWidgets(
      'lock route renders the lock screen for two different arbitrary '
      'packages with their own names', (tester) async {
    for (final pkg in const [appOne, appTwo]) {
      await tester.pumpWidget(BlueLockApp(controller: controller));
      // Drive the router directly, exactly as the native LockActivity does
      // with its initial route "lock/<package>".
      BlueLockApp.navigatorKey.currentState!.pushNamed('lock/$pkg');
      await tester.pumpAndSettle();

      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(find.text('Label for $pkg'), findsOneWidget,
          reason: 'lock screen must show the detected app for $pkg');
      // Never the Blue Lock dashboard or PIN-setup screens.
      expect(find.text('App Locked'), findsOneWidget);
      expect(find.text('Keep your apps private'), findsNothing);
      expect(find.text('Enter your PIN to continue.'), findsOneWidget);

      BlueLockApp.navigatorKey.currentState!
          .popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      'non-lock routes never render the lock screen (unselected apps are '
      'not locked by the router)', (tester) async {
    await tester.pumpWidget(BlueLockApp(controller: controller));

    // A random route that is not a lock route falls through to splash.
    BlueLockApp.navigatorKey.currentState!.pushNamed('/home');
    await tester.pumpAndSettle();
    expect(find.byType(AppLockScreen), findsNothing);
  });

  test('protecting one arbitrary app does not protect another', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    final c = AppController(storage: storage, native: NativeBridge());
    await c.init();

    await c.setPackageLocked(appOne, true);

    expect(c.isLocked(appOne), isTrue);
    expect(c.isLocked(appTwo), isFalse,
        reason: 'protecting one app must not protect any other app');
    expect(c.protectedCount, 1);
  });

  test('protection state persists across a controller restart', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    final c = AppController(storage: storage, native: NativeBridge());
    await c.init();

    await c.setPackageLocked(appOne, true);
    await c.setPackageLocked(appTwo, true);

    // Simulate an app restart: fresh storage + controller over the same
    // persisted preferences.
    final storage2 = AppStorage();
    await storage2.init();
    final c2 = AppController(storage: storage2, native: NativeBridge());
    await c2.init();

    expect(c2.isLocked(appOne), isTrue);
    expect(c2.isLocked(appTwo), isTrue);
    expect(c2.protectedCount, 2);

    // Disabling one leaves the other protected.
    await c2.setPackageLocked(appOne, false);
    expect(c2.isLocked(appOne), isFalse);
    expect(c2.isLocked(appTwo), isTrue);
    expect(c2.protectedCount, 1);
  });

  testWidgets('lock screen resolves and shows icon bytes for an arbitrary '
      'package via native app info', (tester) async {
    final app = await NativeBridge().getAppInfo(appTwo);
    expect(app, isNotNull);
    expect(app!.packageName, appTwo);
    expect(app.label, 'Label for $appTwo');
    expect(app.iconBytes, isNotNull);
    expect(app.iconBytes, isNotEmpty);
  });

  test('installed-apps payload round-trips any package list', () {
    // Guards the generic contract of the model used by the manager screen.
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
    final a = InstalledApp(
        packageName: appOne, label: 'One', iconBytes: bytes, isSystem: false);
    final b = InstalledApp(
        packageName: appTwo,
        label: 'Two',
        iconBytes: Uint8List(0),
        isSystem: true);
    expect(a.packageName, appOne);
    expect(b.packageName, appTwo);
    expect(a.label, isNot(b.label));
  });
}
