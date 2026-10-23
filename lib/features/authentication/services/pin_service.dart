import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/authentication/credential_rules.dart';
import '../../../core/authentication/stored_credential.dart';
import '../../../core/storage/app_storage.dart';
import '../../../core/utils/perf_log.dart';
import '../../../core/utils/pin_crypto.dart';

/// Outcome of one credential verification attempt.
///
/// The name is kept for backwards compatibility with the original PIN-only
/// API; every authentication type (PIN, pattern, password) now uses it.
enum PinVerificationStatus { success, incorrect, lockedOut, noPin }

/// Result of [PinService.verifyPinDetailed] / [PinService.verifyPatternDetailed].
///
/// The message is user-facing and deliberately never contains the attempted
/// credential, its hash or the salt.
class PinVerification {
  const PinVerification._({
    required this.status,
    required this.authType,
    this.remainingAttempts = 0,
    this.lockoutSeconds = 0,
  });

  const PinVerification.success([AuthenticationType authType = AuthenticationType.pin4Digit])
      : this._(status: PinVerificationStatus.success, authType: authType);

  const PinVerification.incorrect(
    int remainingAttempts, [
    AuthenticationType authType = AuthenticationType.pin4Digit,
  ]) : this._(
          status: PinVerificationStatus.incorrect,
          authType: authType,
          remainingAttempts: remainingAttempts,
        );

  const PinVerification.lockedOut(
    int secondsRemaining, [
    AuthenticationType authType = AuthenticationType.pin4Digit,
  ]) : this._(
          status: PinVerificationStatus.lockedOut,
          authType: authType,
          lockoutSeconds: secondsRemaining,
        );

  /// No verifier is stored: this install/device has not completed setup
  /// (e.g. app data migrated without its device-bound secure storage).
  const PinVerification.noPin([AuthenticationType authType = AuthenticationType.pin4Digit])
      : this._(
          status: PinVerificationStatus.noPin,
          authType: authType,
        );

  final PinVerificationStatus status;

  /// The credential type the attempt was checked against. Used for the error
  /// copy and to prove a mode switch cannot leave the UI guessing.
  final AuthenticationType authType;

  /// Attempts left before the next lockout (only meaningful when incorrect).
  final int remainingAttempts;

  /// Seconds until credential entry is accepted again (only when locked out).
  final int lockoutSeconds;

  bool get isSuccess => status == PinVerificationStatus.success;

  bool get isLockedOut => status == PinVerificationStatus.lockedOut;

  String get message {
    switch (status) {
      case PinVerificationStatus.success:
        return '';
      case PinVerificationStatus.lockedOut:
        return 'Too many attempts. Try again in '
            '${_humanizeSeconds(lockoutSeconds)}.';
      case PinVerificationStatus.incorrect:
        final noun = authType.credentialNoun;
        final base = 'Incorrect $noun.';
        if (remainingAttempts > 0 && remainingAttempts <= 2) {
          return '$base $remainingAttempts '
              '${remainingAttempts == 1 ? 'attempt' : 'attempts'} left.';
        }
        return '$base Try again.';
      case PinVerificationStatus.noPin:
        if (authType.isPin) {
          return 'No PIN is set up. Open Blue Lock and finish PIN setup.';
        }
        return 'No ${authType.credentialNoun} is set up. '
            'Open Blue Lock and finish setup.';
    }
  }

  static String _humanizeSeconds(int seconds) {
    if (seconds >= 60) {
      final minutes = (seconds / 60).ceil();
      return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    }
    return '$seconds seconds';
  }
}

/// Creates and verifies the Blue Lock credential using a salted, iterated
/// HMAC-SHA256 verifier. The original PIN/pattern/password is never persisted.
///
/// Derivation runs through [PinCrypto.deriveVerifierAsync]: background
/// isolate on IO platforms, native WebCrypto on the web - so the UI thread
/// is never blocked while the verifier is computed.
///
/// The authentication type is stored inside the credential record. Existing
/// installs without a type are interpreted as a four-digit PIN, and their
/// exact salt/verifier pair is migrated without re-hashing, so existing users
/// keep working.
///
/// Failed attempts are throttled with a persisted counter and lockout
/// deadline. Because the state lives in SharedPreferences it survives
/// reopening the lock activity and restarting the process, and the same
/// counters are shared by every credential type - switching methods cannot
/// bypass a lockout.
class PinService {
  PinService(
    this._storage, {
    Future<Uint8List> Function(String credential, Uint8List salt)? derive,
  }) : _derive = derive ?? PinCrypto.deriveVerifierAsync;

  final AppStorage _storage;
  final Future<Uint8List> Function(String credential, Uint8List salt) _derive;

  /// Attempts allowed in one block before the first (and each later) lockout.
  static const int maxFailedAttempts = 5;

  /// Backoff windows applied to successive lockouts. Capped at 5 minutes so a
  /// legitimate user is never locked out indefinitely.
  static const List<Duration> lockoutDurations = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  bool _hasPin = false;
  AuthenticationType _authType = AuthenticationType.pin4Digit;

  bool get hasPinSync => _hasPin;

  AuthenticationType get authType => _authType;

  /// Loads the credential state for the UI. Best-effort migration of legacy
  /// records happens here: a failed migration leaves the legacy verifier in
  /// place and still sets the correct type.
  Future<void> loadPinState() async {
    try {
      final migrated = await _storage.migrateLegacyCredential();
      if (migrated == null) {
        _hasPin = false;
        _authType = AuthenticationType.pin4Digit;
      } else {
        _hasPin = true;
        _authType = migrated.type;
      }
    } catch (e) {
      // Secure storage unavailable at startup: behave like "no credential
      // yet" so the app can still launch; setup re-persists later.
      _hasPin = false;
      _authType = AuthenticationType.pin4Digit;
      PerfLog.mark('pin: loadPinState failed (${e.runtimeType})');
    }
  }

  /// Reads the selected type without changing setup state. Used by the
  /// pre-warmed lock engine before its first frame.
  Future<AuthenticationType> loadAuthType() async {
    try {
      final credential = await _storage.readCredential();
      if (credential != null) {
        _authType = credential.type;
        _hasPin = true;
      }
    } catch (_) {
      // Keep the conservative four-digit default.
    }
    return _authType;
  }

  Future<bool> hasPin() => _storage.hasPin();

  /// Seconds until credential entry is accepted again, or 0 when not locked.
  Future<int> lockoutRemainingSeconds() async {
    await _storage.reloadPreferences();
    final until = _storage.pinLockoutUntilMs;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until <= now) return 0;
    return ((until - now) / 1000).ceil();
  }

  /// Creates the initial four-digit PIN (backwards-compatible entry point).
  Future<void> createPin(String pin) =>
      createCredential(type: AuthenticationType.pin4Digit, credential: pin);

  /// Creates a credential for [type] and persists type + verifier together.
  Future<void> createCredential({
    required AuthenticationType type,
    required String credential,
  }) async {
    _validateOrThrow(type, credential);
    await _persistCredential(type: type, credential: credential);
    // A newly created credential invalidates every earlier failure/lockout.
    await _storage.clearPinAttemptState();
  }

  /// Convenience wrapper for pattern setup. Throws [PinException] when the
  /// sequence is too short or repeats a dot.
  Future<void> createPattern(List<int> dots) =>
      createCredential(
        type: AuthenticationType.pattern,
        credential: CredentialRules.encodePattern(dots),
      );

  /// Verifies [credential] against the persisted type, recording the attempt
  /// for rate limiting.
  ///
  /// Pattern credentials must use [CredentialRules.encodePattern]; callers
  /// with a dot list can use [verifyPatternDetailed].
  Future<PinVerification> verifyPinDetailed(String credential) =>
      _verify(credential);

  /// Verifies an ordered pattern dot sequence.
  Future<PinVerification> verifyPatternDetailed(List<int> dots) {
    if (!CredentialRules.isValidPatternDots(dots)) {
      // Invalid/incomplete patterns are treated as a failed attempt, but
      // never hashed as if they were a different credential.
      return _verify('', formatValidOverride: false);
    }
    return _verify(CredentialRules.encodePattern(dots));
  }

  /// Backwards-compatible boolean verification. Screens should prefer
  /// [verifyPinDetailed] so they can show lockout/remaining-attempt messages.
  Future<bool> verifyPin(String credential) async =>
      (await verifyPinDetailed(credential)).isSuccess;

  Future<PinVerification> _verify(
    String credential, {
    bool? formatValidOverride,
  }) async {
    // See AppStorage.reloadPreferences: the other engine may have recorded
    // failures/lockout that this isolate's cached snapshot does not know.
    await _storage.reloadPreferences();
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = _storage.pinLockoutUntilMs;

    final credentialRecord = await _storage.readCredential();
    final type = credentialRecord?.type ?? _authType;
    if (until > now) {
      return PinVerification.lockedOut(
        ((until - now) / 1000).ceil(),
        type,
      );
    }

    var failedAttempts = _storage.pinFailedAttempts;
    final lockoutStage = _storage.pinLockoutStage;
    if (until != 0) {
      // Deadline elapsed: clear the stale marker but keep the backoff stage.
      await _storage.setPinAttemptState(
        failedAttempts: failedAttempts,
        lockoutUntilMs: 0,
        lockoutStage: lockoutStage,
      );
    }

    if (credentialRecord == null) {
      // Not a wrong credential - no verifier exists (setup incomplete, or
      // app data was restored without the device-bound secure storage). Do
      // not consume an attempt or pretend the user typed something wrong.
      _hasPin = false;
      return PinVerification.noPin(type);
    }

    _hasPin = true;
    _authType = type;

    final formatValid = formatValidOverride ??
        CredentialRules.isValid(credentialRecord.type, credential);
    var ok = false;
    if (formatValid) {
      ok = await _verifyAgainst(
        credential,
        saltB64: credentialRecord.saltB64,
        verifierB64: credentialRecord.verifierB64,
      );
    }

    if (ok) {
      await _storage.clearPinAttemptState();
      return PinVerification.success(type);
    }

    failedAttempts += 1;
    if (failedAttempts >= maxFailedAttempts) {
      final nextStage = math.min(lockoutStage + 1, lockoutDurations.length);
      final wait = lockoutDurations[nextStage - 1];
      final newUntil = now + wait.inMilliseconds;
      await _storage.setPinAttemptState(
        failedAttempts: 0,
        lockoutUntilMs: newUntil,
        lockoutStage: nextStage,
      );
      PerfLog.mark('auth: lockout stage $nextStage for ${wait.inSeconds}s');
      return PinVerification.lockedOut(wait.inSeconds, type);
    }

    await _storage.setPinAttemptState(
      failedAttempts: failedAttempts,
      lockoutUntilMs: 0,
      lockoutStage: lockoutStage,
    );
    return PinVerification.incorrect(maxFailedAttempts - failedAttempts, type);
  }

  Future<bool> _verifyAgainst(
    String credential, {
    required String saltB64,
    required String verifierB64,
  }) async {
    final salt = PinCrypto.saltFromBase64(saltB64);
    final expected = PinCrypto.verifierFromBase64(verifierB64);
    final deriveWatch = Stopwatch()..start();
    final actual = await _derive(credential, salt);
    deriveWatch.stop();
    PerfLog.mark(
        'auth: verify derive completed in ${deriveWatch.elapsedMilliseconds}ms');
    return PinCrypto.constantTimeEquals(expected, actual);
  }

  /// Changes a PIN (backwards-compatible entry point).
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) =>
      changeCredential(
        currentCredential: currentPin,
        newType: AuthenticationType.pin4Digit,
        newCredential: newPin,
      );

  /// Verifies the current credential, then atomically replaces it (and the
  /// authentication type, if it changed).
  ///
  /// The old verifier is only overwritten after the new one has been written
  /// and read back successfully. If saving fails, the previous credential
  /// remains valid and the exception is rethrown to the caller.
  Future<void> changeCredential({
    required String currentCredential,
    required AuthenticationType newType,
    required String newCredential,
  }) async {
    final result = await verifyPinDetailed(currentCredential);
    if (!result.isSuccess) {
      throw PinException(result.message.isEmpty
          ? 'Current ${result.authType.credentialNoun} is incorrect.'
          : result.message);
    }
    if (result.authType == newType && currentCredential == newCredential) {
      throw PinException(newType.sameCredentialMessage);
    }
    await replaceCredential(type: newType, credential: newCredential);
  }

  /// Persists a new credential after the caller has already authenticated
  /// the current one. Used by the Change Lock Type flow so the current
  /// credential is not derived twice.
  ///
  /// Prefer [changeCredential] when the current credential has not been
  /// verified yet.
  Future<void> replaceCredential({
    required AuthenticationType type,
    required String credential,
  }) async {
    _validateOrThrow(type, credential);
    final previousType = _authType;
    final previousHasPin = _hasPin;
    try {
      await _persistCredential(type: type, credential: credential);
    } catch (_) {
      // The previous verifier record is untouched by a failed write, but
      // restore the in-memory view as well so the UI stays consistent.
      _authType = previousType;
      _hasPin = previousHasPin;
      rethrow;
    }
    await _storage.clearPinAttemptState();
  }

  Future<void> _persistCredential({
    required AuthenticationType type,
    required String credential,
  }) async {
    final salt = PinCrypto.generateSalt();
    final deriveWatch = Stopwatch()..start();
    final verifier = await _derive(credential, salt);
    deriveWatch.stop();
    PerfLog.mark(
        'auth: derive completed in ${deriveWatch.elapsedMilliseconds}ms');
    final saveWatch = Stopwatch()..start();
    await _storage.saveCredential(StoredCredential(
      type: type,
      saltB64: PinCrypto.saltToBase64(salt),
      verifierB64: PinCrypto.verifierToBase64(verifier),
    ));
    saveWatch.stop();
    PerfLog.mark(
        'auth: verifier persisted in ${saveWatch.elapsedMilliseconds}ms');
    _authType = type;
    _hasPin = true;
  }

  void _validateOrThrow(AuthenticationType type, String credential) {
    final error = CredentialRules.validate(type, credential);
    if (error != null) throw PinException(error);
  }
}

class PinException implements Exception {
  const PinException(this.message);
  final String message;

  @override
  String toString() => message;
}
