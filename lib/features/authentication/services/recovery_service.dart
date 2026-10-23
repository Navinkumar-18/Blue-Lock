import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/authentication/recovery_code.dart';
import '../../../core/storage/app_storage.dart';
import '../../../core/utils/perf_log.dart';
import '../../../core/utils/pin_crypto.dart';
import 'pin_service.dart';

/// Outcome of one recovery-code attempt.
enum RecoveryVerificationStatus { success, incorrect, lockedOut, notConfigured }

class RecoveryVerification {
  const RecoveryVerification._({
    required this.status,
    this.remainingAttempts = 0,
    this.lockoutSeconds = 0,
  });

  const RecoveryVerification.success()
    : this._(status: RecoveryVerificationStatus.success);

  const RecoveryVerification.incorrect(int remainingAttempts)
    : this._(
        status: RecoveryVerificationStatus.incorrect,
        remainingAttempts: remainingAttempts,
      );

  const RecoveryVerification.lockedOut(int lockoutSeconds)
    : this._(
        status: RecoveryVerificationStatus.lockedOut,
        lockoutSeconds: lockoutSeconds,
      );

  const RecoveryVerification.notConfigured()
    : this._(status: RecoveryVerificationStatus.notConfigured);

  final RecoveryVerificationStatus status;
  final int remainingAttempts;
  final int lockoutSeconds;

  bool get isSuccess => status == RecoveryVerificationStatus.success;

  bool get isLockedOut => status == RecoveryVerificationStatus.lockedOut;

  String get message {
    switch (status) {
      case RecoveryVerificationStatus.success:
        return '';
      case RecoveryVerificationStatus.lockedOut:
        final wait = lockoutSeconds >= 60
            ? '${(lockoutSeconds / 60).ceil()} '
                  '${(lockoutSeconds / 60).ceil() == 1 ? 'minute' : 'minutes'}'
            : '$lockoutSeconds seconds';
        return 'Too many recovery attempts. Try again in $wait.';
      case RecoveryVerificationStatus.incorrect:
        if (remainingAttempts > 0 && remainingAttempts <= 2) {
          return 'Incorrect recovery code. $remainingAttempts '
              '${remainingAttempts == 1 ? 'attempt' : 'attempts'} left.';
        }
        return 'Incorrect recovery code. Try again.';
      case RecoveryVerificationStatus.notConfigured:
        return 'No recovery code is configured on this device.';
    }
  }
}

/// Creates and verifies the recovery code.
///
/// Storage design matches the primary credential: a fresh 16-byte salt and a
/// PBKDF2-HMAC-SHA256 verifier are stored; the plaintext code exists only in
/// memory while it is displayed once. Recovery attempts share the persisted
/// failed-attempt/lockout counters with the primary credential, so switching
/// between PIN, pattern, password and recovery cannot bypass a lockout.
class RecoveryService {
  RecoveryService(
    this._storage, {
    Future<Uint8List> Function(String credential, Uint8List salt)? derive,
  }) : _derive = derive ?? PinCrypto.deriveVerifierAsync;

  final AppStorage _storage;
  final Future<Uint8List> Function(String credential, Uint8List salt) _derive;

  Future<bool> hasRecoveryCode() async =>
      (await _storage.readRecoveryVerifier()) != null;

  /// Generates a new recovery code, stores only its verifier and returns the
  /// plaintext code so the caller can display it once. Nothing is logged.
  ///
  /// Throws when secure storage fails; in that case any previously configured
  /// recovery code is still the verifier in storage.
  Future<String> createRecoveryCode() async {
    final code = RecoveryCode.generate();
    final salt = PinCrypto.generateSalt();
    final deriveWatch = Stopwatch()..start();
    final verifier = await _derive(code, salt);
    deriveWatch.stop();
    PerfLog.mark(
      'recovery: verifier derived in ${deriveWatch.elapsedMilliseconds}ms',
    );
    await _storage.saveRecoveryVerifier(
      saltB64: PinCrypto.saltToBase64(salt),
      verifierB64: PinCrypto.verifierToBase64(verifier),
    );
    // A new factor starts with a clean attempt history.
    await _storage.clearPinAttemptState();
    return code;
  }

  /// Verifies [input] against the stored recovery verifier.
  ///
  /// Malformed codes are treated exactly like wrong codes (one failed
  /// attempt) but are never hashed as if they were a valid credential.
  Future<RecoveryVerification> verifyCode(String input) async {
    await _storage.reloadPreferences();
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = _storage.pinLockoutUntilMs;
    if (until > now) {
      return RecoveryVerification.lockedOut(((until - now) / 1000).ceil());
    }

    final record = await _storage.readRecoveryVerifier();
    if (record == null) return const RecoveryVerification.notConfigured();

    var failedAttempts = _storage.pinFailedAttempts;
    final lockoutStage = _storage.pinLockoutStage;
    if (until != 0) {
      await _storage.setPinAttemptState(
        failedAttempts: failedAttempts,
        lockoutUntilMs: 0,
        lockoutStage: lockoutStage,
      );
    }

    final canonical = RecoveryCode.normalize(input);
    var ok = false;
    if (canonical != null) {
      final salt = PinCrypto.saltFromBase64(record.saltB64);
      final expected = PinCrypto.verifierFromBase64(record.verifierB64);
      final actual = await _derive(canonical, salt);
      ok = PinCrypto.constantTimeEquals(expected, actual);
    }

    if (ok) {
      await _storage.clearPinAttemptState();
      return const RecoveryVerification.success();
    }

    failedAttempts += 1;
    if (failedAttempts >= PinService.maxFailedAttempts) {
      final nextStage = math.min(
        lockoutStage + 1,
        PinService.lockoutDurations.length,
      );
      final wait = PinService.lockoutDurations[nextStage - 1];
      await _storage.setPinAttemptState(
        failedAttempts: 0,
        lockoutUntilMs: now + wait.inMilliseconds,
        lockoutStage: nextStage,
      );
      PerfLog.mark('recovery: lockout stage $nextStage for ${wait.inSeconds}s');
      return RecoveryVerification.lockedOut(wait.inSeconds);
    }

    await _storage.setPinAttemptState(
      failedAttempts: failedAttempts,
      lockoutUntilMs: 0,
      lockoutStage: lockoutStage,
    );
    return RecoveryVerification.incorrect(
      PinService.maxFailedAttempts - failedAttempts,
    );
  }

  /// Seconds until a locked-out recovery attempt is accepted again.
  Future<int> lockoutRemainingSeconds() async {
    await _storage.reloadPreferences();
    final until = _storage.pinLockoutUntilMs;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until <= now) return 0;
    return ((until - now) / 1000).ceil();
  }
}
