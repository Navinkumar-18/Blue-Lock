import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../authentication/authentication_type.dart';
import '../authentication/recovery_code.dart';
import '../authentication/stored_credential.dart';

/// Persistence layer: secure storage holds the credential verifier, shared
/// preferences holds app selections and settings.
///
/// Credential format (v2): the existing `pin_verifier` key holds one JSON
/// record containing the authentication type, salt and derived verifier. A
/// single secure-storage write therefore commits a complete credential, so a
/// failed change can never leave a salt from one credential next to a
/// verifier from another.
///
/// Existing installs are read without rewriting: a raw Base64 `pin_verifier`
/// plus `pin_salt` is interpreted as a four-digit PIN and is migrated lazily
/// after a successful read. The exact same salt/verifier bytes are copied, so
/// the old credential keeps working.
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

  /// Recovery-code verifier. Separate from the primary credential so a
  /// forgotten PIN/pattern/password never invalidates the recovery factor.
  /// Existing installs simply have no record: they are explicitly told that
  /// no recovery code was configured instead of receiving an unseen one.
  static const _kRecoveryVerifier = 'recovery_verifier';

  /// Legacy standalone type key. New records embed the type in
  /// [_kPinVerifier]; this is only read for installs that already have it.
  static const _kAuthType = 'auth_type';

  static const int _credentialVersion = 2;
  static const int _recoveryVersion = 1;

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

  // ---- Credential verifier (secure) ----

  /// Reads the stored credential. Returns null when setup never completed or
  /// the record is incomplete.
  ///
  /// Reading never mutates storage. Call [migrateLegacyCredential] when a
  /// write is acceptable (startup/setup) to upgrade the legacy layout.
  Future<StoredCredential?> readCredential() async {
    final rawVerifier = await _readSecure(_kPinVerifier);
    if (rawVerifier == null || rawVerifier.isEmpty) return null;

    final record = _parseRecord(rawVerifier);
    if (record != null) return record;

    // Legacy layout: raw Base64 verifier + separate salt. Existing installs
    // had no type field and were always four-digit PINs.
    final salt = await _readSecure(_kPinSalt);
    if (salt == null || salt.isEmpty) return null;
    final legacyType =
        AuthenticationType.tryParse(await _readSecure(_kAuthType)) ??
            AuthenticationType.pin4Digit;
    return StoredCredential(
      type: legacyType,
      saltB64: salt,
      verifierB64: rawVerifier,
      isLegacy: true,
    );
  }

  /// Upgrades a legacy record to the single-record v2 format.
  ///
  /// The same salt and verifier are copied verbatim, so verification keeps
  /// working. A failure (e.g. secure storage temporarily unavailable) is
  /// swallowed: the caller still has the legacy credential and nothing was
  /// removed.
  Future<StoredCredential?> migrateLegacyCredential() async {
    final credential = await readCredential();
    if (credential == null || !credential.isLegacy) return credential;
    try {
      await saveCredential(StoredCredential(
        type: credential.type,
        saltB64: credential.saltB64,
        verifierB64: credential.verifierB64,
      ));
      return StoredCredential(
        type: credential.type,
        saltB64: credential.saltB64,
        verifierB64: credential.verifierB64,
      );
    } catch (_) {
      return credential;
    }
  }

  /// Atomically persists a complete credential (type + salt + verifier).
  ///
  /// The record is written to one secure key and read back. Only after that
  /// succeeds is the legacy salt mirror updated. A change of credential or
  /// authentication type therefore either commits entirely or leaves the
  /// previous record untouched.
  Future<void> saveCredential(StoredCredential credential) async {
    final payload = jsonEncode(<String, Object>{
      'v': _credentialVersion,
      'type': credential.type.storageValue,
      'salt': credential.saltB64,
      'verifier': credential.verifierB64,
    });

    await _writeSecure(_kPinVerifier, payload);
    final readBack = await _readSecure(_kPinVerifier);
    if (readBack != payload) {
      throw StateError('Credential verifier did not persist to secure storage.');
    }

    // Compatibility mirror for any older reader that only looks at
    // `pin_salt`. The authoritative record above already contains everything
    // needed, so a failure here cannot corrupt the credential.
    try {
      await _writeSecure(_kPinSalt, credential.saltB64);
    } catch (_) {
      // See above: the v2 record is complete and authoritative.
    }
    // Older builds stored the type separately. Keep it in sync for those
    // readers; new readers ignore it when the v2 record is present.
    try {
      await _writeSecure(_kAuthType, credential.type.storageValue);
    } catch (_) {
      // Optional compatibility mirror only.
    }
  }

  /// Backwards-compatible entry point used by older callers/tests. New code
  /// should use [saveCredential] with an explicit [AuthenticationType].
  Future<void> savePinVerifier({
    required String saltB64,
    required String verifierB64,
  }) =>
      saveCredential(StoredCredential(
        type: AuthenticationType.pin4Digit,
        saltB64: saltB64,
        verifierB64: verifierB64,
      ));

  Future<String?> readPinSalt() => _readSecure(_kPinSalt);

  Future<String?> readPinVerifier() => _readSecure(_kPinVerifier);

  /// The selected authentication type, or null when no credential exists.
  Future<AuthenticationType?> readAuthType() async {
    final credential = await readCredential();
    return credential?.type;
  }

  Future<bool> hasPin() async => (await readCredential()) != null;

  // ---- Recovery-code verifier (secure) ----

  /// The recovery verifier, or null when no recovery code has been set up.
  /// A legacy installation has no record and must not be treated as damaged:
  /// the caller shows an explicit "no recovery code configured" message.
  Future<RecoveryVerifier?> readRecoveryVerifier() async {
    final raw = await _readSecure(_kRecoveryVerifier);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != _recoveryVersion) return null;
      final salt = decoded['salt'];
      final verifier = decoded['verifier'];
      if (salt is! String ||
          verifier is! String ||
          salt.isEmpty ||
          verifier.isEmpty) {
        return null;
      }
      return RecoveryVerifier(saltB64: salt, verifierB64: verifier);
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasRecoveryVerifier() async =>
      (await readRecoveryVerifier()) != null;

  /// Persists a complete recovery verifier and reads it back. A failed write
  /// throws and leaves any previous recovery code in place; callers must not
  /// report success before this returns.
  Future<void> saveRecoveryVerifier({
    required String saltB64,
    required String verifierB64,
  }) async {
    final payload = jsonEncode(<String, Object>{
      'v': _recoveryVersion,
      'salt': saltB64,
      'verifier': verifierB64,
    });
    await _writeSecure(_kRecoveryVerifier, payload);
    final readBack = await _readSecure(_kRecoveryVerifier);
    if (readBack != payload) {
      throw StateError('Recovery verifier did not persist to secure storage.');
    }
  }

  Future<void> clearRecoveryVerifier() => _secureDelete(_kRecoveryVerifier);

  StoredCredential? _parseRecord(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != _credentialVersion) return null;
      final type = AuthenticationType.tryParse(decoded['type'] as String?);
      final salt = decoded['salt'];
      final verifier = decoded['verifier'];
      if (type == null ||
          salt is! String ||
          verifier is! String ||
          salt.isEmpty ||
          verifier.isEmpty) {
        return null;
      }
      return StoredCredential(
        type: type,
        saltB64: salt,
        verifierB64: verifier,
      );
    } catch (_) {
      return null;
    }
  }

  // ---- Failed-attempt throttling ----
  //
  // The same persisted counters are shared by every authentication type and
  // by both Dart engines, so switching methods or recreating the activity
  // cannot reset a lockout.

  int get pinFailedAttempts => prefs.getInt(_kPinFailedAttempts) ?? 0;

  /// Wall-clock time before which credential verification is refused
  /// (0 = none).
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
