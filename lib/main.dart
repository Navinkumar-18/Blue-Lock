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

  // Mirror current configuration to the native lock service so protection
  // survives process restarts.
  await controller.native.setProtectedPackages(
    controller.lockedPackages.toList(),
  );
  await controller.native.setLockEnabled(controller.lockEnabled);
  await controller.native.setRelockTimeout(controller.relockTimeoutSeconds);

  runApp(BlueLockApp(controller: controller));
}
