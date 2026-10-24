import 'package:flutter/foundation.dart';

import '../../features/app_lock/services/biometric_status.dart';
import '../../features/chat_lock/models/chat_identity.dart';
import '../../features/chat_lock/models/chat_lock_state.dart';
import '../../features/installed_apps/models/installed_app.dart';
import '../../features/installed_apps/services/apps_repository.dart';
import '../../features/authentication/services/pin_service.dart';
import '../../features/authentication/services/recovery_service.dart';
import '../../features/permissions/services/permissions_service.dart';
import '../authentication/authentication_type.dart';
import '../services/native_bridge.dart';
import '../storage/app_storage.dart';
import '../utils/perf_log.dart';

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
        recoveryService = services?.recovery ??
            RecoveryService(
              storage,
              derive: services?.derive,
            ),
        appsRepository = services?.apps ?? AppsRepository(native),
        permissions = services?.permissions ?? PermissionsService(native) {
    lockedPackages = storage.lockedPackages.toSet();
    relockTimeoutSeconds = storage.relockTimeoutSeconds;
    _lockEnabled = storage.lockEnabled;
    _chatLockEnabled = storage.chatLockEnabled;
    chatRelockTimeoutSeconds = storage.chatRelockTimeoutSeconds;
    protectedChats = storage.protectedChats
        .map(ChatIdentity.normalize)
        .whereType<String>()
        .toSet();
  }

  final AppStorage storage;
  final NativeBridge native;
  final PinService pinService;
  final RecoveryService recoveryService;
  final AppsRepository appsRepository;
  final PermissionsService permissions;

  Set<String> lockedPackages = <String>{};
  int relockTimeoutSeconds = 0;
  bool _lockEnabled = true;
  bool onboardingDone = false;

  // Experimental Instagram Chat Lock. The local settings are the source of
  // truth; native mirrors them for the accessibility service. Only normalised
  // usernames are kept - never display names or message content.
  bool _chatLockEnabled = false;
  int chatRelockTimeoutSeconds = 0;
  Set<String> protectedChats = <String>{};
  ChatLockState chatLockState = ChatLockState.unknown;

  List<InstalledApp> installedApps = const [];
  bool appsLoading = false;
  String? appsError;

  bool usageAccess = false;
  bool overlayPermission = false;
  bool notificationPermission = true;
  bool batteryOptimizationIgnored = true;

  // Biometric unlock: device capability (available/enrolled) + user pref.
  BiometricStatus biometric = BiometricStatus.unavailable;

  bool get lockEnabled => _lockEnabled;
  bool get hasPin => pinService.hasPinSync;
  bool get chatLockEnabled => _chatLockEnabled;

  /// The selected lock method. Every authentication entry point reads this
  /// from the same [PinService], which loads it from the encrypted credential
  /// record (defaulting existing installs to a four-digit PIN).
  AuthenticationType get authType => pinService.authType;

  /// Blue Lock's own unlock session (self-lock). Cached so the app-entry
  /// gate can decide synchronously; the source of truth is native LockPrefs
  /// which survives backgrounding and process restarts correctly.
  bool selfUnlocked = false;

  /// Self-lock only applies once setup finished: without a stored PIN there
  /// is nothing to authenticate against, so first-run onboarding stays open.
  bool get selfSetupDone => onboardingDone && hasPin;

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
    // Mirror the selected method to native Android so both sides agree after
    // service/activity recreation. The secure credential record remains the
    // source of truth; this is a one-way mirror of the type only.
    await native.setAuthType(authType);
    // Mirror the experimental chat configuration to native storage so the
    // accessibility service keeps working while Flutter is paused.
    await native.setChatLockEnabled(_chatLockEnabled);
    await native.setProtectedChats(protectedChats.toList());
    await native.setChatRelockTimeout(chatRelockTimeoutSeconds);
    await refreshPermissions();
    await refreshBiometrics();
    await refreshSelfSession();
    await refreshChatLockState();
  }

  /// Saves the initial credential and its authentication type.
  Future<void> createCredential({
    required AuthenticationType type,
    required String credential,
  }) async {
    await pinService.createCredential(type: type, credential: credential);
    await native.setAuthType(type);
    notifyListeners();
  }

  /// Replaces the credential after the current one was verified by a screen.
  /// The old verifier remains intact when persistence fails.
  Future<void> replaceCredential({
    required AuthenticationType type,
    required String credential,
  }) async {
    await pinService.replaceCredential(type: type, credential: credential);
    await native.setAuthType(type);
    notifyListeners();
  }

  /// Re-reads Blue Lock's own unlock session from native storage. An expired
  /// or missing session locks the app-entry gate; a still-valid timed
  /// session keeps it open (e.g. returning within the configured window).
  Future<void> refreshSelfSession() async {
    selfUnlocked = await native.isSelfUnlocked();
    notifyListeners();
  }

  /// Records a successful Blue Lock authentication under the relock policy
  /// and opens the app-entry gate.
  Future<void> grantSelfSession() async {
    await native.unlockSelf();
    selfUnlocked = true;
    notifyListeners();
  }

  /// Blue Lock left the foreground: apply the relock policy natively and
  /// reflect the immediate case in the cached gate state.
  Future<void> onSelfBackgrounded() async {
    await native.onSelfBackgrounded();
    if (relockTimeoutSeconds <= 0) {
      selfUnlocked = false;
      notifyListeners();
    }
  }

  /// Expires Blue Lock's own session without touching the credential.
  Future<void> revokeSelfSession() async {
    await native.lockSelf();
    selfUnlocked = false;
    notifyListeners();
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
    notifyListeners();
    await storage.setBiometricEnabled(enabled);
    await native.setBiometricEnabled(enabled);
  }

  Future<void> refreshPermissions() async {
    usageAccess = await permissions.hasUsageAccess();
    overlayPermission = await permissions.hasOverlayPermission();
    notificationPermission = await permissions.hasNotificationPermission();
    batteryOptimizationIgnored =
        await permissions.isIgnoringBatteryOptimizations();
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
      final watch = Stopwatch()..start();
      installedApps = await appsRepository.getInstalledApps();
      appsError = null;
      PerfLog.mark(
          'apps: discovered ${installedApps.length} in ${watch.elapsedMilliseconds}ms');
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
    // Publish the new state first so the switch flips on the next frame,
    // then persist to storage and native. Every step below is fallible but
    // cheap; waiting for all three before notifying made each toggle wait
    // on a SharedPreferences write plus two platform-channel round trips.
    notifyListeners();
    await storage.setLockedPackages(next.toList());
    await native.setProtectedPackages(next.toList());
    // Clear any stale unlock session for this app (lock or unlock).
    await native.lockPackage(packageName);
    return true;
  }

  Future<void> setLockEnabled(bool enabled) async {
    _lockEnabled = enabled;
    notifyListeners();
    await storage.setLockEnabled(enabled);
    await native.setLockEnabled(enabled);
  }

  Future<void> setRelockTimeout(int seconds) async {
    relockTimeoutSeconds = seconds;
    notifyListeners();
    await storage.setRelockTimeoutSeconds(seconds);
    await native.setRelockTimeout(seconds);
  }

  // ---- experimental Instagram Chat Lock ----

  Future<void> refreshChatLockState() async {
    chatLockState = await native.getChatLockState();
    notifyListeners();
  }

  Future<void> setChatLockEnabled(bool enabled) async {
    _chatLockEnabled = enabled;
    notifyListeners();
    await storage.setChatLockEnabled(enabled);
    await native.setChatLockEnabled(enabled);
    await refreshChatLockState();
  }

  Future<void> setChatRelockTimeout(int seconds) async {
    chatRelockTimeoutSeconds = seconds;
    notifyListeners();
    await storage.setChatRelockTimeoutSeconds(seconds);
    await native.setChatRelockTimeout(seconds);
    await refreshChatLockState();
  }

  /// Adds a normalised username. Returns a user-facing error, or null on
  /// success. Display names are rejected by [ChatIdentity.normalize].
  Future<String?> addProtectedChat(String rawUsername) async {
    final id = ChatIdentity.normalize(rawUsername);
    if (id == null) {
      return 'Enter a valid Instagram username: letters, numbers, dots or '
          'underscores, up to 30 characters.';
    }
    if (protectedChats.contains(id)) {
      return '@$id is already protected.';
    }
    protectedChats = <String>{...protectedChats, id};
    notifyListeners();
    await storage.setProtectedChats(protectedChats.toList());
    await native.setProtectedChats(protectedChats.toList());
    await refreshChatLockState();
    return null;
  }

  Future<void> removeProtectedChat(String username) async {
    final id = ChatIdentity.normalize(username);
    if (id == null || !protectedChats.contains(id)) return;
    protectedChats = <String>{...protectedChats}..remove(id);
    notifyListeners();
    await storage.setProtectedChats(protectedChats.toList());
    // Native clears the removed conversation's session as part of this call.
    await native.setProtectedChats(protectedChats.toList());
    await refreshChatLockState();
  }

  Future<void> openChatAccessibilitySettings() =>
      native.openChatAccessibilitySettings();

  /// Expires all conversation sessions without touching the protected list.
  Future<void> clearChatLockSessions() async {
    await native.clearChatLockSessions();
    await refreshChatLockState();
  }

  Future<void> markOnboardingDone() async {
    onboardingDone = true;
    await storage.setOnboardingDone(true);
    notifyListeners();
  }

  /// Applies a new credential after the user has *verified* a recovery
  /// factor (enrolled biometrics or the recovery code).
  ///
  /// This is deliberately not a reset: protected-app selections, the relock
  /// policy, biometric preference and the monitoring service all stay intact.
  /// Only the credential verifier and authentication type are replaced, and
  /// every existing unlock session is revoked so protected apps require the
  /// new credential. If persistence fails the previous credential remains
  /// valid and the error is rethrown to the recovery screen.
  Future<void> completeRecovery({
    required AuthenticationType type,
    required String credential,
  }) async {
    await pinService.replaceCredential(type: type, credential: credential);
    await native.setAuthType(type);
    // A forgotten credential may have left old unlock sessions behind.
    // Revoke them; the user proves the new credential on the lock screen.
    await native.lockAllSessions();
    selfUnlocked = false;
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
    this.recovery,
    this.apps,
    this.permissions,
    this.derive,
  });
  final PinService? pin;
  final RecoveryService? recovery;
  final AppsRepository? apps;
  final PermissionsService? permissions;

  /// PBKDF2 derivation override (tests inject the synchronous variant to
  /// keep the flow deterministic off the isolate path).
  final Future<Uint8List> Function(String pin, Uint8List salt)? derive;
}
