import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:blue_lock/core/utils/pin_crypto.dart';

/// The async derivation path must stay byte-identical to the reference
/// PBKDF2 vector on every platform: background isolate on IO platforms,
/// native WebCrypto on the web (run with `flutter test --platform chrome`).
///
/// Vector generated with OpenSSL:
///   PBKDF2-HMAC-SHA256(password='1234', salt=000102...0f,
///                       iterations=120000, dkLen=32)
const _expectedHex =
    '5070321ca34dbdafe9b25371d1c0f83bcafe073fbae1f2274f00a6d6c68e9899';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('deriveVerifierAsync matches the OpenSSL PBKDF2 vector', () async {
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final sw = Stopwatch()..start();
    final v = await PinCrypto.deriveVerifierAsync('1234', salt);
    sw.stop();
    // ignore: avoid_print
    print('[perf] deriveVerifierAsync took ${sw.elapsedMilliseconds}ms');
    expect(_hex(v), _expectedHex);
  });
}
