import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:blue_lock/core/utils/pin_crypto.dart';

/// Known-answer tests against an independent PBKDF2 vector.
///
/// Vector generated with OpenSSL (not our own implementation):
///   PBKDF2-HMAC-SHA256(password='1234', salt=000102...0f,
///                       iterations=120000, dkLen=32)
///   = 5070321ca34dbdafe9b25371d1c0f83bcafe073fbae1f2274f00a6d6c68e9899
const _expectedHex =
    '5070321ca34dbdafe9b25371d1c0f83bcafe073fbae1f2274f00a6d6c68e9899';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));

  test('deriveVerifier (synchronous) matches the OpenSSL vector', () {
    expect(_hex(PinCrypto.deriveVerifier('1234', salt)), _expectedHex);
  });

  test('deriveVerifierChunked matches the OpenSSL vector', () async {
    final v = await PinCrypto.deriveVerifierChunked('1234', salt);
    expect(_hex(v), _expectedHex);
  });
}
