import 'dart:typed_data';

import '../../../core/storage/app_storage.dart';
import '../../../core/utils/perf_log.dart';
import '../../../core/utils/pin_crypto.dart';

/// Creates and verifies the app PIN using a salted, iterated HMAC-SHA256
/// verifier. The original PIN is never persisted.
///
/// Derivation runs through [PinCrypto.deriveVerifierAsync]: background
/// isolate on IO platforms, native WebCrypto on the web - so the UI thread
/// is never blocked while the verifier is computed.
class PinService {
  PinService(
    this._storage, {
    Future<Uint8List> Function(String pin, Uint8List salt)? derive,
  }) : _derive = derive ?? PinCrypto.deriveVerifierAsync;

  final AppStorage _storage;
  final Future<Uint8List> Function(String pin, Uint8List salt) _derive;

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
    _hasPin = true;
  }

  Future<bool> verifyPin(String pin) async {
    _validatePin(pin);
    final saltB64 = await _storage.readPinSalt();
    final verifierB64 = await _storage.readPinVerifier();
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
    final ok = await verifyPin(currentPin);
    if (!ok) {
      throw const PinException('Current PIN is incorrect.');
    }
    if (currentPin == newPin) {
      throw const PinException('New PIN must be different from the current PIN.');
    }
    await createPin(newPin);
  }

  Future<void> resetAll() async {
    await _storage.clearPin();
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
