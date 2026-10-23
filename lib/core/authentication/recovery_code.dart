import 'dart:math';

/// One-time recovery codes used when the primary credential is forgotten.
///
/// The plaintext code is shown exactly once during setup and is never stored.
/// Only [RecoveryVerifier] (salt + PBKDF2 verifier) is persisted.
class RecoveryCode {
  RecoveryCode._();

  /// Ambiguous characters (I, O, 0, 1) are omitted so a hand-written code is
  /// less likely to be mistyped. 32 symbols makes generation unbiased with
  /// `Random.secure().nextInt(32)`.
  static const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static const int characters = 16;
  static const int groupSize = 4;

  /// 16 * log2(32) = 80 bits of entropy.
  static final Random _random = Random.secure();

  /// Generates a cryptographically secure code (plaintext, never persisted).
  static String generate() {
    final buffer = StringBuffer();
    for (var i = 0; i < characters; i++) {
      buffer.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// Canonicalises user input: uppercase and separators removed. Interior
  /// characters are never otherwise altered, and an invalid code returns null
  /// instead of being silently "fixed" into something else.
  static String? normalize(String input) {
    final cleaned = input.toUpperCase().replaceAll(RegExp(r'[\s\-_]'), '');
    if (cleaned.length != characters) return null;
    for (final unit in cleaned.codeUnits) {
      if (!alphabet.codeUnits.contains(unit)) return null;
    }
    return cleaned;
  }

  /// Human-readable "XXXX-XXXX-XXXX-XXXX" form for display/printing.
  static String format(String code) {
    final canonical = normalize(code);
    if (canonical == null) return code;
    final groups = <String>[];
    for (var i = 0; i < canonical.length; i += groupSize) {
      groups.add(canonical.substring(i, i + groupSize));
    }
    return groups.join('-');
  }
}

/// Persisted recovery-code verifier. The plaintext code is never part of this
/// object, so it cannot be logged or serialised accidentally.
class RecoveryVerifier {
  const RecoveryVerifier({required this.saltB64, required this.verifierB64});

  final String saltB64;
  final String verifierB64;
}
