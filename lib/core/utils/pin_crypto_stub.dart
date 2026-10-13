import 'dart:typed_data';

/// Platform-specific asynchronous PBKDF2 dispatch. Every conditional branch
/// must export this exact signature. See `pin_crypto.dart`.
Future<Uint8List> deriveVerifierAsync(String pin, Uint8List salt) {
  throw UnsupportedError(
    'deriveVerifierAsync is not available on this platform.',
  );
}
