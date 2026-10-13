import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'pin_crypto.dart';

/// Web: use the browser's native WebCrypto PBKDF2 implementation.
///
/// Same PBKDF2-HMAC-SHA-256 algorithm, salt and iteration count as the
/// pure-Dart implementation - byte-identical output - but executed in
/// native code: milliseconds instead of tens of seconds of pure-Dart crypto
/// blocking the main thread.
///
/// If WebCrypto is unavailable (e.g. insecure context) or anything fails,
/// falls back to the chunked pure-Dart derivation, which yields to the event
/// loop so the UI can still paint while it runs.
Future<Uint8List> deriveVerifierAsync(String pin, Uint8List salt) async {
  try {
    final subtle = _cryptoSubtleJs;
    if (subtle == null) {
      return await PinCrypto.deriveVerifierChunked(pin, salt);
    }

    final key = await _SubtleCrypto(subtle)
        .importKey(
          'raw'.toJS,
          utf8.encode(pin).toJS,
          'PBKDF2'.toJS,
          false.toJS,
          <JSString>['deriveBits'.toJS].toJS,
        )
        .toDart;

    final params = JSObject()
      ..setProperty('name'.toJS, 'PBKDF2'.toJS)
      ..setProperty('hash'.toJS, 'SHA-256'.toJS)
      ..setProperty('salt'.toJS, salt.toJS)
      ..setProperty('iterations'.toJS, PinCrypto.iterations.toJS);

    final bits = await _SubtleCrypto(subtle)
        .deriveBits(params, key, (PinCrypto.derivedKeyLength * 8).toJS)
        .toDart;
    return Uint8List.view(bits.toDart);
  } catch (_) {
    return await PinCrypto.deriveVerifierChunked(pin, salt);
  }
}

/// `crypto.subtle` if the browser exposes it (null in insecure contexts).
@JS('crypto.subtle')
external JSObject? get _cryptoSubtleJs;

/// Minimal typed facade over `SubtleCrypto` for the two methods we need.
@JS()
extension type _SubtleCrypto(JSObject _) implements JSObject {
  external JSPromise<JSObject> importKey(
    JSAny format,
    JSObject keyData,
    JSAny algorithm,
    JSAny extractable,
    JSArray<JSString> usages,
  );

  external JSPromise<JSArrayBuffer> deriveBits(
    JSObject algorithm,
    JSObject baseKey,
    JSAny length,
  );
}
