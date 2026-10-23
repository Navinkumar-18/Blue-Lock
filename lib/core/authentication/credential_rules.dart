import 'authentication_type.dart';

/// Validation and canonical encoding rules shared by every authentication
/// entry point (onboarding, lock screens, change flows, tests).
///
/// Rules are intentionally centralised: the UI and verifier must never
/// disagree about what a valid credential is.
class CredentialRules {
  CredentialRules._();

  /// A pattern must connect at least this many different dots.
  static const int minPatternDots = 4;

  /// 3 x 3 dot grid, indexed row-major 0..8.
  static const int patternGridSize = 3;
  static const int patternDotCount = patternGridSize * patternGridSize;

  /// Passwords are not forced to a PIN-like length. These are minimum and
  /// maximum sanity bounds only; the credential is hashed exactly as entered.
  static const int minPasswordLength = 4;
  static const int maxPasswordLength = 256;

  /// Domain-separated, deterministic representation of an ordered dot
  /// sequence. The raw pattern is never persisted.
  static String encodePattern(Iterable<int> dots) {
    final list = dots.toList(growable: false);
    if (!isValidPatternDots(list)) {
      throw ArgumentError.value(
        list,
        'dots',
        'A pattern needs at least $minPatternDots different dots (0..8).',
      );
    }
    return 'pattern:v1:${list.join('-')}';
  }

  /// Returns the ordered dot list for a canonical pattern string, or null.
  static List<int>? decodePattern(String value) {
    const prefix = 'pattern:v1:';
    if (!value.startsWith(prefix)) return null;
    final raw = value.substring(prefix.length);
    if (raw.isEmpty) return null;
    final parts = raw.split('-');
    final dots = <int>[];
    for (final part in parts) {
      final dot = int.tryParse(part);
      if (dot == null) return null;
      dots.add(dot);
    }
    return isValidPatternDots(dots) ? dots : null;
  }

  /// True when [dots] is an ordered sequence of at least [minPatternDots]
  /// distinct dots inside the 3 x 3 grid.
  static bool isValidPatternDots(Iterable<int> dots) {
    final seen = <int>{};
    var count = 0;
    for (final dot in dots) {
      if (dot < 0 || dot >= patternDotCount) return false;
      if (!seen.add(dot)) return false;
      count++;
    }
    return count >= minPatternDots;
  }

  static bool _isAsciiDigits(String value) {
    if (value.isEmpty) return false;
    for (final unit in value.codeUnits) {
      if (unit < 0x30 || unit > 0x39) return false;
    }
    return true;
  }

  /// Returns a user-facing validation error, or null when [credential] is
  /// valid for [type].
  static String? validate(AuthenticationType type, String credential) {
    switch (type) {
      case AuthenticationType.pin4Digit:
      case AuthenticationType.pin6Digit:
        final length = type.pinLength!;
        if (credential.length != length || !_isAsciiDigits(credential)) {
          return 'PIN must be exactly $length digits.';
        }
        return null;
      case AuthenticationType.pattern:
        return decodePattern(credential) == null
            ? 'Pattern must connect at least $minPatternDots different dots.'
            : null;
      case AuthenticationType.password:
        // Whitespace-only credentials are rejected, but surrounding spaces in
        // a real password are significant and are never trimmed.
        if (credential.isEmpty || credential.trim().isEmpty) {
          return 'Password cannot be empty or whitespace only.';
        }
        if (credential.length < minPasswordLength) {
          return 'Password must be at least $minPasswordLength characters.';
        }
        if (credential.length > maxPasswordLength) {
          return 'Password must be at most $maxPasswordLength characters.';
        }
        return null;
    }
  }

  static bool isValid(AuthenticationType type, String credential) =>
      validate(type, credential) == null;
}
