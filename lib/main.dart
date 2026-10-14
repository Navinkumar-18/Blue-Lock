import 'package:flutter/material.dart';

import 'app.dart';
import 'core/services/native_bridge.dart';
import 'core/state/app_controller.dart';
import 'core/storage/app_storage.dart';
import 'core/utils/perf_log.dart';

Future<void> main() async {
  // Wall-clock stamp (ms since epoch) so logcat lines from this isolate can
  // be correlated with native SystemClock-based lines via the shared logd
  // clock. PerfLog's own +Xms values are relative to this isolate's start
  // only and must not be mixed with elapsedRealtime values directly.
  PerfLog.mark('dart: main entered at ${DateTime.now().millisecondsSinceEpoch}');
  WidgetsFlutterBinding.ensureInitialized();
  // Frame-timing capture for device profiling (debug/profile builds only;
  // compiled out of release).
  PerfLog.startFrameWatch();

  final storage = AppStorage();
  await storage.init();
  PerfLog.mark('dart: storage ready');

  final controller = AppController(
    storage: storage,
    native: NativeBridge(),
  );

  final defaultRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final isLockRoute =
      defaultRoute.startsWith('lock/') || defaultRoute.startsWith('/lock/');
  if (isLockRoute) {
    // The engine booted by LockActivity renders authentication UI only.
    // controller.init() would preload PIN state (a secure-storage read),
    // query permissions, biometrics and the self-session over four
    // platform-channel round trips - none of which the lock screen uses
    // (it reads the PIN verifier on demand at verify time and fetches its
    // biometric status over the lock channel). Skipping it keeps the first
    // frame free of unrelated async work.
    PerfLog.mark('dart: lock route - skipping dashboard init');
  } else {
    await controller.init();
    // Mirror current configuration to the native lock service so protection
    // survives process restarts.
    await controller.native.setProtectedPackages(
      controller.lockedPackages.toList(),
    );
    await controller.native.setLockEnabled(controller.lockEnabled);
    await controller.native.setRelockTimeout(controller.relockTimeoutSeconds);
    await controller.native.setBiometricEnabled(controller.biometricEnabled);
  }

  // Blue Lock's own self-authentication gate and lifecycle session handling
  // must not run on the lock engine.
  runApp(BlueLockApp(controller: controller, selfLockHost: !isLockRoute));
  PerfLog.mark('dart: runApp issued');
}
