import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistence layer: secure storage holds the PIN verifier, shared
/// preferences holds app selections and settings.
///
/// If platform channels are unavailable (unit/widget tests - no handler
/// registered), secure values fall back to an in-memory map so the UI
/// remains testable. Real platform failures propagate to the caller: a
/// failed write must never be mistaken for a successful save.
class AppStorage {
  AppStorage({SharedPreferences? preferences, FlutterSecureStorage? secure})
      : _prefs = preferences,
        _secure = secure ?? const FlutterSecureStorage();

  static const _kOnboardingDone = 'onboarding_done';
  static const _kLockedPackages = 'locked_packages';
  static const _kRelockTimeout = 'relock_timeout_seconds';
  static const _kLockEnabled = 'lock_enabled';
  static const _kBiometricEnabled = 'biometric_enabled';

  static const _kPinSalt = 'pin_salt';
  static const _kPinVerifier = 'pin_verifier';

  // Failed-attempt throttling. Persisted (not in memory) so reopening the
  // activity or restarting the process cannot reset the counter.
  static const _kPinFailedAttempts = 'pin_failed_attempts';
  static const _kPinLockoutUntil = 'pin_lockout_until_ms';
  static const _kPinLockoutStage = 'pin_lockout_stage';

  final SharedPreferences? _prefs;
  final FlutterSecureStorage _secure;

  final Map<String, String> _memorySecure = {};
  SharedPreferences? _resolvedPrefs;

  SharedPreferences get prefs {
    final resolved = _prefs ?? _resolvedPrefs;
    if (resolved == null) {
      throw StateError('AppStorage.init() must be awaited before use.');
    }
    return resolved;
  }

  Future<void> init() async {
    if (_prefs == null) {
      _resolvedPrefs = await SharedPreferences.getInstance();
    }
  }

  /// Re-reads preferences from disk.
  ///
  /// Blue Lock can run two Dart isolates in one process (dashboard engine +
  /// pre-warmed lock engine), and each isolate caches SharedPreferences
  /// values. Reloading before security-sensitive reads (PIN attempt state)
  /// keeps a lockout granted in one engine visible in the other instead of
  /// letting the second engine overwrite it with a stale counter.
  Future<void> reloadPreferences() => prefs.reload();

  // ---- PIN verifier (secure) ----

  Future<void> savePinVerifier(
      {required String saltB64, required String verifierB64}) async {
    await Future.wait([
      _writeSecure(_kPinSalt, saltB64),
      _writeSecure(_kPinVerifier, verifierB64),
    ]);
    // Read back after writing: callers (PIN setup) treat this future as the
    // gate for marking setup complete, so a write that silently did not
    // persist must fail loudly here.
    final written = await Future.wait([
      readPinSalt(),
      readPinVerifier(),
    ]);
    if (written[0] != saltB64 || written[1] != verifierB64) {
      throw StateError('PIN verifier did not persist to secure storage.');
    }
  }

  Future<String?> readPinSalt() => _readSecure(_kPinSalt);

  Future<String?> readPinVerifier() => _readSecure(_kPinVerifier);

  Future<bool> hasPin() async {
    final verifier = await readPinVerifier();
    return verifier != null && verifier.isNotEmpty;
  }

  Future<void> clearPin() async {
    await _secureDelete(_kPinSalt);
    await _secureDelete(_kPinVerifier);
  }

  // ---- PIN failed-attempt throttling ----

  int get pinFailedAttempts => prefs.getInt(_kPinFailedAttempts) ?? 0;

  /// Wall-clock time before which PIN verification is refused (0 = none).
  int get pinLockoutUntilMs => prefs.getInt(_kPinLockoutUntil) ?? 0;

  /// How many lockout windows have already been served; drives the backoff.
  int get pinLockoutStage => prefs.getInt(_kPinLockoutStage) ?? 0;

  Future<void> setPinAttemptState({
    required int failedAttempts,
    required int lockoutUntilMs,
    required int lockoutStage,
  }) async {
    await prefs.setInt(_kPinFailedAttempts, failedAttempts);
    await prefs.setInt(_kPinLockoutUntil, lockoutUntilMs);
    await prefs.setInt(_kPinLockoutStage, lockoutStage);
  }

  Future<void> clearPinAttemptState() =>
      setPinAttemptState(failedAttempts: 0, lockoutUntilMs: 0, lockoutStage: 0);

  // ---- Settings ----

  bool get onboardingDone => prefs.getBool(_kOnboardingDone) ?? false;

  Future<void> setOnboardingDone(bool value) => prefs.setBool(_kOnboardingDone, value);

  List<String> get lockedPackages =>
      (prefs.getStringList(_kLockedPackages) ?? const []).toList();

  Future<void> setLockedPackages(List<String> packages) =>
      prefs.setStringList(_kLockedPackages, packages);

  // Default 0 = "Immediately after leaving an app", matching the native side.
  int get relockTimeoutSeconds => prefs.getInt(_kRelockTimeout) ?? 0;

  Future<void> setRelockTimeoutSeconds(int seconds) =>
      prefs.setInt(_kRelockTimeout, seconds);

  bool get lockEnabled => prefs.getBool(_kLockEnabled) ?? true;

  Future<void> setLockEnabled(bool value) => prefs.setBool(_kLockEnabled, value);

  /// Whether biometric unlock is offered on the lock screen (user pref).
  bool get biometricEnabled => prefs.getBool(_kBiometricEnabled) ?? true;

  Future<void> setBiometricEnabled(bool value) =>
      prefs.setBool(_kBiometricEnabled, value);

  // ---- secure helpers: in-memory fallback only when the platform channel
  // is absent (tests). Any real platform failure propagates. ----

  Future<void> _writeSecure(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
    } on MissingPluginException {
      _memorySecure[key] = value;
    }
  }

  Future<String?> _readSecure(String key) async {
    try {
      return await _secure.read(key: key);
    } on MissingPluginException {
      return _memorySecure[key];
    }
  }

  Future<void> _secureDelete(String key) async {
    try {
      await _secure.delete(key: key);
    } on MissingPluginException {
      _memorySecure.remove(key);
    }
  }
}
