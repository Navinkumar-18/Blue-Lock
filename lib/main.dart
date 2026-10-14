import 'package:flutter/material.dart';

import 'app.dart';
import 'core/services/native_bridge.dart';
import 'core/state/app_controller.dart';
import 'core/storage/app_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storage = AppStorage();
  await storage.init();

  final controller = AppController(
    storage: storage,
    native: NativeBridge(),
  );
  await controller.init();

  final defaultRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final isLockRoute =
      defaultRoute.startsWith('lock/') || defaultRoute.startsWith('/lock/');
  if (!isLockRoute) {
    // Mirror current configuration to the native lock service so protection
    // survives process restarts.
    await controller.native.setProtectedPackages(
      controller.lockedPackages.toList(),
    );
    await controller.native.setLockEnabled(controller.lockEnabled);
    await controller.native.setRelockTimeout(controller.relockTimeoutSeconds);
    await controller.native.setBiometricEnabled(controller.biometricEnabled);
  }

  // The engine booted by LockActivity only ever renders the lock screen for
  // a protected app: Blue Lock's own self-authentication gate and lifecycle
  // session handling must not run there.
  runApp(BlueLockApp(controller: controller, selfLockHost: !isLockRoute));
}
