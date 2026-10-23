import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/features/settings/presentation/settings_screen.dart';

/// Regression test for:
/// "ListTile background color or ink splashes may be invisible."
///
/// ListTile reports that error via FlutterError.reportError from a debug
/// assertion when a painted DecoratedBox sits between it and the nearest
/// Material. flutter_test runs with asserts enabled (like a Chrome debug
/// run) and fails the test on any reported FlutterError, so pumping the
/// Settings screen - which contains four ListTiles inside cards - proves
/// the hierarchy is fixed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppController controller;

  setUpAll(() async {
    // Mock the native channel so invokeMethod futures complete inside the
    // FakeAsync zone of testWidgets (unmocked platform responses complete
    // outside it, which would stall notifyListeners and rebuilds).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async => null);

    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    controller = AppController(
      storage: storage,
      native: NativeBridge(),
    );
    await controller.init();
  });

  testWidgets('settings ListTiles render without background assertion',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(controller: controller),
    ));
    await tester.pumpAndSettle();

    expect(find.text('App-lock protection'), findsOneWidget);
    expect(find.text('Change PIN'), findsOneWidget);
    expect(find.text('Preview lock screen'), findsOneWidget);
    expect(find.text('Usage Access'), findsOneWidget);
    expect(find.text('Display Over Other Apps'), findsOneWidget);

    // Interaction still works: toggling the protection switch flips state.
    final switchBefore = controller.lockEnabled;
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(controller.lockEnabled, !switchBefore);

    // Tap back to restore state for other tests.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(controller.lockEnabled, switchBefore);
  });

  testWidgets('about card shows the installed version from the platform',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async {
      if (call.method == 'getAppVersion') {
        return <String, dynamic>{
          'versionName': '1.0.1',
          'versionCode': 2002,
        };
      }
      return null;
    });

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(controller: controller),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Version 1.0.1 (2002)'), findsOneWidget);
  });
}
