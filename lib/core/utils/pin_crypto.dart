import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pin_crypto_stub.dart'
    if (dart.library.io) 'pin_crypto_io.dart'
    if (dart.library.js_interop) 'pin_crypto_web.dart' as platform;

/// Salted, iterated HMAC-SHA256 verifier (PBKDF2-style) for the 4-digit PIN.
/// The original PIN is never stored - only salt + verifier.
class PinCrypto {
  PinCrypto._();

  static const int saltLength = 16;
  static const int iterations = 120000;
  static const int derivedKeyLength = 32;

  static final Random _random = Random.secure();

  static Uint8List generateSalt() {
    final bytes = Uint8List(saltLength);
    for (var i = 0; i < saltLength; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  /// Standard PBKDF2-HMAC-SHA256, single block (dkLen <= hash length):
  /// U1 = HMAC(key=pin, msg=salt || INT_BE(1)), T = U1 xor U2 xor ... The PIN
  /// is the HMAC key; the salt blocks the message side.
  static Uint8List deriveVerifier(String pin, Uint8List salt) {
    final pinKey = utf8.encode(pin);
    final salted = Uint8List(salt.length + 4);
    salted.setAll(0, salt);
    salted[salt.length] = 0;
    salted[salt.length + 1] = 0;
    salted[salt.length + 2] = 0;
    salted[salt.length + 3] = 1;

    var u = Hmac(sha256, pinKey).convert(salted).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = Hmac(sha256, pinKey).convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    return t.sublist(0, derivedKeyLength);
  }

  /// Asynchronous derivation with identical output to [deriveVerifier].
  ///
  /// - On IO platforms (Android, the primary target) the 120k-iteration
  ///   PBKDF2 work runs in a background isolate so the UI thread never
  ///   blocks during PIN creation or verification.
  /// - On the web, the platform's native WebCrypto PBKDF2 implementation is
  ///   used (same algorithm, same iterations, byte-identical result), with a
  ///   chunked pure-Dart fallback that yields to the event loop.
  static Future<Uint8List> deriveVerifierAsync(String pin, Uint8List salt) =>
      platform.deriveVerifierAsync(pin, salt);

  /// Same PBKDF2 work as [deriveVerifier], but yields to the event loop
  /// every few milliseconds so frames can paint while it runs. Used as the
  /// web fallback when WebCrypto is unavailable (e.g. insecure context).
  static Future<Uint8List> deriveVerifierChunked(String pin, Uint8List salt) async {
    final pinKey = utf8.encode(pin);
    final salted = Uint8List(salt.length + 4);
    salted.setAll(0, salt);
    salted[salt.length] = 0;
    salted[salt.length + 1] = 0;
    salted[salt.length + 2] = 0;
    salted[salt.length + 3] = 1;

    final hmac = Hmac(sha256, pinKey);
    var u = hmac.convert(salted).bytes;
    final t = Uint8List.fromList(u);
    final yieldWatch = Stopwatch();
    yieldWatch.start();
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
      if ((i & 511) == 0 && yieldWatch.elapsedMicroseconds > 12000) {
        yieldWatch.reset();
        await Future<void>.delayed(Duration.zero);
      }
    }
    return t.sublist(0, derivedKeyLength);
  }

  static String saltToBase64(Uint8List salt) => base64Encode(salt);

  static Uint8List saltFromBase64(String value) => base64Decode(value);

  static String verifierToBase64(Uint8List verifier) => base64Encode(verifier);

  static Uint8List verifierFromBase64(String value) => base64Decode(value);

  /// Constant-time comparison of two byte sequences.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
