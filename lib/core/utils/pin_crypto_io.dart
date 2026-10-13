import 'package:flutter/foundation.dart';

import 'pin_crypto.dart';

/// IO platforms (Android, iOS, desktop): run the 120k-iteration PBKDF2
/// derivation in a background isolate so the UI thread stays responsive
/// while the PIN verifier is derived.
Future<Uint8List> deriveVerifierAsync(String pin, Uint8List salt) {
  return compute(_deriveInBackground, (pin, salt));
}

Uint8List _deriveInBackground((String, Uint8List) input) {
  return PinCrypto.deriveVerifier(input.$1, input.$2);
}
