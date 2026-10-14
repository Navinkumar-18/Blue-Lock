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
