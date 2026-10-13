import 'package:flutter/foundation.dart';

import '../../features/app_lock/services/biometric_status.dart';
import '../../features/installed_apps/models/installed_app.dart';
import '../../features/installed_apps/services/apps_repository.dart';
import '../../features/authentication/services/pin_service.dart';
import '../../features/permissions/services/permissions_service.dart';
import '../services/native_bridge.dart';
import '../storage/app_storage.dart';

/// Relock policy choices shown in Settings (seconds). 0 = immediately after
/// leaving the app.
class RelockOption {
  const RelockOption(this.label, this.seconds);
  final String label;
  final int seconds;

  static const values = <RelockOption>[
    RelockOption('Immediately after leaving an app', 0),
    RelockOption('After 30 seconds', 30),
    RelockOption('After 1 minute', 60),
    RelockOption('After 5 minutes', 300),
  ];
}

/// Single source of truth for app-wide state. Persisted values are mirrored
/// to native Android so the lock service works even when Flutter is paused.
class AppController extends ChangeNotifier {
  AppController({
    required this.storage,
    required this.native,
    AppControllerServices? services,
  })  : pinService = services?.pin ??
            PinService(
              storage,
              derive: services?.derive,
            ),
        appsRepository = services?.apps ?? AppsRepository(native),
        permissions = services?.permissions ?? PermissionsService(native) {
    lockedPackages = storage.lockedPackages.toSet();
    relockTimeoutSeconds = storage.relockTimeoutSeconds;
    _lockEnabled = storage.lockEnabled;
  }

  final AppStorage storage;
  final NativeBridge native;
  final PinService pinService;
  final AppsRepository appsRepository;
  final PermissionsService permissions;

  Set<String> lockedPackages = <String>{};
  int relockTimeoutSeconds = 30;
  bool _lockEnabled = true;
  bool onboardingDone = false;

  List<InstalledApp> installedApps = const [];
  bool appsLoading = false;
  String? appsError;

  bool usageAccess = false;
  bool overlayPermission = false;

  // Biometric unlock: device capability (available/enrolled) + user pref.
  BiometricStatus biometric = BiometricStatus.unavailable;

  bool get lockEnabled => _lockEnabled;
  bool get hasPin => pinService.hasPinSync;

  bool get biometricEnabled => biometric.enabled;
  bool get biometricUsable => biometric.canUse;

  bool get permissionsGranted => usageAccess;

  int get protectedCount => lockedPackages.length;

  bool isLocked(String packageName) => lockedPackages.contains(packageName);

  Future<void> init() async {
    onboardingDone = storage.onboardingDone;
    biometric = BiometricStatus(
      available: false,
      enrolled: false,
      enabled: storage.biometricEnabled,
    );
    await pinService.loadPinState();
    await refreshPermissions();
    await refreshBiometrics();
  }

  Future<void> refreshBiometrics() async {
    final status = await native.getBiometricStatus();
    biometric = status;
    notifyListeners();
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    biometric = BiometricStatus(
      available: biometric.available,
      enrolled: biometric.enrolled,
      enabled: enabled,
    );
    await storage.setBiometricEnabled(enabled);
    await native.setBiometricEnabled(enabled);
    notifyListeners();
  }

  Future<void> refreshPermissions() async {
    usageAccess = await permissions.hasUsageAccess();
    overlayPermission = await permissions.hasOverlayPermission();
    notifyListeners();
  }

  // ---- installed apps ----

  Future<void> loadInstalledApps({bool force = false}) async {
    if (appsLoading) return;
    if (!force && installedApps.isNotEmpty) return;
    appsLoading = true;
    appsError = null;
    notifyListeners();
    try {
      installedApps = await appsRepository.getInstalledApps();
      appsError = null;
    } catch (e) {
      appsError = 'Could not load installed apps.';
      installedApps = const [];
    } finally {
      appsLoading = false;
      notifyListeners();
    }
  }

  // ---- lock configuration ----

  Future<bool> setPackageLocked(String packageName, bool locked) async {
    final next = lockedPackages.toSet();
    final changed = locked ? next.add(packageName) : next.remove(packageName);
    if (!changed) return true;
    lockedPackages = next;
    await storage.setLockedPackages(next.toList());
    await native.setProtectedPackages(next.toList());
    // Clear any stale unlock session for this app (lock or unlock).
    await native.lockPackage(packageName);
    notifyListeners();
    return true;
  }

  Future<void> setLockEnabled(bool enabled) async {
    _lockEnabled = enabled;
    await storage.setLockEnabled(enabled);
    await native.setLockEnabled(enabled);
    notifyListeners();
  }

  Future<void> setRelockTimeout(int seconds) async {
    relockTimeoutSeconds = seconds;
    await storage.setRelockTimeoutSeconds(seconds);
    await native.setRelockTimeout(seconds);
    notifyListeners();
  }

  Future<void> markOnboardingDone() async {
    onboardingDone = true;
    await storage.setOnboardingDone(true);
    notifyListeners();
  }

  /// Recovery for a forgotten PIN: wipes the PIN verifier and protected
  /// apps so the user can set up Blue Lock again. The original PIN cannot
  /// be recovered.
  Future<void> resetProtection() async {
    await pinService.resetAll();
    lockedPackages = <String>{};
    await storage.setLockedPackages(const []);
    await native.setProtectedPackages(const []);
    _lockEnabled = true;
    await storage.setLockEnabled(true);
    await native.setLockEnabled(true);
    onboardingDone = false;
    await storage.setOnboardingDone(false);
    notifyListeners();
  }

  InstalledApp? findApp(String packageName) {
    for (final app in installedApps) {
      if (app.packageName == packageName) return app;
    }
    return null;
  }
}

/// Optional injection point for tests.
class AppControllerServices {
  const AppControllerServices({
    this.pin,
    this.apps,
    this.permissions,
    this.derive,
  });
  final PinService? pin;
  final AppsRepository? apps;
  final PermissionsService? permissions;

  /// PBKDF2 derivation override (tests inject the synchronous variant to
  /// keep the flow deterministic off the isolate path).
  final Future<Uint8List> Function(String pin, Uint8List salt)? derive;
}
