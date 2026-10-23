import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/storage/app_storage.dart';
import '../../../core/utils/perf_log.dart';
import '../../../core/utils/pin_crypto.dart';

/// Outcome of one PIN verification attempt.
enum PinVerificationStatus { success, incorrect, lockedOut, noPin }

/// Result of [PinService.verifyPinDetailed].
///
/// The message is user-facing and deliberately never contains the attempted
/// PIN, its hash or the salt.
class PinVerification {
  const PinVerification._({
    required this.status,
    this.remainingAttempts = 0,
    this.lockoutSeconds = 0,
  });

  const PinVerification.success()
      : this._(status: PinVerificationStatus.success);

  const PinVerification.incorrect(int remainingAttempts)
      : this._(
          status: PinVerificationStatus.incorrect,
          remainingAttempts: remainingAttempts,
        );

  const PinVerification.lockedOut(int secondsRemaining)
      : this._(
          status: PinVerificationStatus.lockedOut,
          lockoutSeconds: secondsRemaining,
        );

  /// No verifier is stored: this install/device has not completed PIN setup
  /// (e.g. app data migrated without its device-bound secure storage).
  const PinVerification.noPin() : this._(status: PinVerificationStatus.noPin);

  final PinVerificationStatus status;

  /// Attempts left before the next lockout (only meaningful when incorrect).
  final int remainingAttempts;

  /// Seconds until PIN entry is accepted again (only when locked out).
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
        if (remainingAttempts > 0 && remainingAttempts <= 2) {
          return 'Incorrect PIN. $remainingAttempts '
              '${remainingAttempts == 1 ? 'attempt' : 'attempts'} left.';
        }
        return 'Incorrect PIN. Try again.';
      case PinVerificationStatus.noPin:
        return 'No PIN is set up. Open Blue Lock and finish PIN setup.';
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

/// Creates and verifies the app PIN using a salted, iterated HMAC-SHA256
/// verifier. The original PIN is never persisted.
///
/// Derivation runs through [PinCrypto.deriveVerifierAsync]: background
/// isolate on IO platforms, native WebCrypto on the web - so the UI thread
/// is never blocked while the verifier is computed.
///
/// Failed attempts are throttled with a persisted counter and lockout
/// deadline. Because the state lives in SharedPreferences it survives
/// reopening the lock activity and restarting the process, so neither is a
/// way to reset the counter. A user who clears app data can still reset it -
/// that is intentionally the same destructive path as forgetting the PIN.
class PinService {
  PinService(
    this._storage, {
    Future<Uint8List> Function(String pin, Uint8List salt)? derive,
  }) : _derive = derive ?? PinCrypto.deriveVerifierAsync;

  final AppStorage _storage;
  final Future<Uint8List> Function(String pin, Uint8List salt) _derive;

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

  bool get hasPinSync => _hasPin;

  Future<void> loadPinState() async {
    try {
      _hasPin = await _storage.hasPin();
    } catch (e) {
      // Secure storage unavailable at startup: behave like "no PIN yet" so
      // the app can still launch; setup re-persists the verifier later.
      _hasPin = false;
      PerfLog.mark('pin: loadPinState failed (${e.runtimeType})');
    }
  }

  Future<bool> hasPin() => _storage.hasPin();

  /// Seconds until PIN entry is accepted again, or 0 when not locked out.
  Future<int> lockoutRemainingSeconds() async {
    await _storage.reloadPreferences();
    final until = _storage.pinLockoutUntilMs;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until <= now) return 0;
    return ((until - now) / 1000).ceil();
  }

  Future<void> createPin(String pin) async {
    _validatePin(pin);
    final salt = PinCrypto.generateSalt();
    final deriveWatch = Stopwatch()..start();
    final verifier = await _derive(pin, salt);
    deriveWatch.stop();
    PerfLog.mark('pin: derive completed in ${deriveWatch.elapsedMilliseconds}ms');
    final saveWatch = Stopwatch()..start();
    await _storage.savePinVerifier(
      saltB64: PinCrypto.saltToBase64(salt),
      verifierB64: PinCrypto.verifierToBase64(verifier),
    );
    saveWatch.stop();
    PerfLog.mark('pin: verifier persisted in ${saveWatch.elapsedMilliseconds}ms');
    // A newly created PIN invalidates every earlier failure/lockout.
    await _storage.clearPinAttemptState();
    _hasPin = true;
  }

  /// Verifies [pin], recording the attempt for rate limiting.
  Future<PinVerification> verifyPinDetailed(String pin) async {
    _validatePin(pin);
    // See AppStorage.reloadPreferences: the other engine may have recorded
    // failures/lockout that this isolate's cached snapshot does not know.
    await _storage.reloadPreferences();
    final now = DateTime.now().millisecondsSinceEpoch;
    final until = _storage.pinLockoutUntilMs;

    if (until > now) {
      return PinVerification.lockedOut(((until - now) / 1000).ceil());
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

    final saltB64 = await _storage.readPinSalt();
    final verifierB64 = await _storage.readPinVerifier();
    final ok = await _verifyAgainst(
      pin,
      saltB64: saltB64,
      verifierB64: verifierB64,
    );

    if (ok) {
      await _storage.clearPinAttemptState();
      return const PinVerification.success();
    }

    if (saltB64 == null || verifierB64 == null) {
      // Not a wrong PIN - no verifier exists (setup incomplete, or app data
      // was restored without the device-bound secure storage). Do not
      // consume an attempt or pretend the user typed something wrong.
      return const PinVerification.noPin();
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
      PerfLog.mark('pin: lockout stage $nextStage for ${wait.inSeconds}s');
      return PinVerification.lockedOut(wait.inSeconds);
    }

    await _storage.setPinAttemptState(
      failedAttempts: failedAttempts,
      lockoutUntilMs: 0,
      lockoutStage: lockoutStage,
    );
    return PinVerification.incorrect(maxFailedAttempts - failedAttempts);
  }

  /// Backwards-compatible boolean verification. Screens should prefer
  /// [verifyPinDetailed] so they can show lockout/remaining-attempt messages.
  Future<bool> verifyPin(String pin) async =>
      (await verifyPinDetailed(pin)).isSuccess;

  Future<bool> _verifyAgainst(
    String pin, {
    required String? saltB64,
    required String? verifierB64,
  }) async {
    if (saltB64 == null || verifierB64 == null) return false;
    final salt = PinCrypto.saltFromBase64(saltB64);
    final expected = PinCrypto.verifierFromBase64(verifierB64);
    final deriveWatch = Stopwatch()..start();
    final actual = await _derive(pin, salt);
    deriveWatch.stop();
    PerfLog.mark('pin: verify derive completed in ${deriveWatch.elapsedMilliseconds}ms');
    return PinCrypto.constantTimeEquals(expected, actual);
  }

  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    final result = await verifyPinDetailed(currentPin);
    if (!result.isSuccess) {
      throw PinException(result.message.isEmpty
          ? 'Current PIN is incorrect.'
          : result.message);
    }
    if (currentPin == newPin) {
      throw const PinException('New PIN must be different from the current PIN.');
    }
    await createPin(newPin);
  }

  Future<void> resetAll() async {
    await _storage.clearPin();
    await _storage.clearPinAttemptState();
    _hasPin = false;
  }

  void _validatePin(String pin) {
    final digitsOnly = pin.split('').every((c) => int.tryParse(c) != null);
    if (pin.length != 4 || !digitsOnly) {
      throw const PinException('PIN must be exactly 4 digits.');
    }
  }
}

class PinException implements Exception {
  const PinException(this.message);
  final String message;

  @override
  String toString() => message;
}
