/// The lock credential a user has configured for Blue Lock.
///
/// [storageValue] is the stable wire value. It is written into the encrypted
/// credential record and mirrored to native Android, so it must never be
/// renamed without a migration.
enum AuthenticationType {
  pin4Digit(
    storageValue: 'pin_4_digit',
    title: 'Four-Digit PIN',
    shortLabel: '4-digit PIN',
    credentialNoun: 'PIN',
    description: 'A familiar four-digit PIN.',
    pinLength: 4,
  ),
  pin6Digit(
    storageValue: 'pin_6_digit',
    title: 'Six-Digit PIN',
    shortLabel: '6-digit PIN',
    credentialNoun: 'PIN',
    description: 'More digits for stronger protection.',
    pinLength: 6,
  ),
  pattern(
    storageValue: 'pattern',
    title: 'Pattern Lock',
    shortLabel: 'pattern',
    credentialNoun: 'pattern',
    description: 'Connect at least four dots in a 3 x 3 grid.',
  ),
  password(
    storageValue: 'password',
    title: 'Password',
    shortLabel: 'password',
    credentialNoun: 'password',
    description: 'Letters, numbers and special characters.',
  );

  const AuthenticationType({
    required this.storageValue,
    required this.title,
    required this.shortLabel,
    required this.credentialNoun,
    required this.description,
    this.pinLength,
  });

  /// Stable value persisted in secure storage and native preferences.
  final String storageValue;

  /// Human readable name used on the Choose Lock Type screen.
  final String title;

  /// Short name used inside sentences ("Enter your 4-digit PIN").
  final String shortLabel;

  /// Noun used in messages ("Incorrect PIN/pattern/password").
  final String credentialNoun;

  /// One-line explanation shown under the option.
  final String description;

  /// Exact digit count for PIN types, null for pattern/password.
  final int? pinLength;

  bool get isPin => pinLength != null;

  bool get isPattern => this == AuthenticationType.pattern;

  bool get isPassword => this == AuthenticationType.password;

  /// Existing installs without a stored type were always four-digit PINs.
  /// Unknown values also fall back safely instead of locking the user out.
  static AuthenticationType fromStorage(String? value) =>
      tryParse(value) ?? AuthenticationType.pin4Digit;

  /// Parses a persisted value, returning null when it is unknown.
  static AuthenticationType? tryParse(String? value) {
    if (value == null) return null;
    for (final type in AuthenticationType.values) {
      if (type.storageValue == value) return type;
    }
    return null;
  }

  /// "Forgot PIN?" / "Forgot pattern?" / "Forgot password?"
  String get forgotLabel => 'Forgot $credentialNoun?';

  /// "Enter your PIN to continue." etc. (capitalised first word).
  String get verifyDescription {
    if (isPin) return 'Enter your PIN to continue.';
    if (isPattern) return 'Draw your pattern to continue.';
    return 'Enter your password to continue.';
  }

  /// Copy used by the initial setup screen.
  String get setupHeading {
    if (isPin) return pinLength == 4 ? 'Create your PIN' : 'Create your $shortLabel';
    if (isPattern) return 'Draw your pattern';
    return 'Create your password';
  }

  String get setupDescription {
    if (isPin) {
      return pinLength == 4
          ? 'This 4-digit PIN will unlock your protected apps.'
          : 'Choose a 6-digit PIN to unlock your protected apps.';
    }
    if (isPattern) {
      return 'Connect at least 4 dots. You will draw the same pattern again '
          'to confirm it.';
    }
    return 'Use letters, and add numbers or symbols for a stronger password. '
        'You will enter it again to confirm it.';
  }

  String get confirmHeading {
    if (isPin) {
      return pinLength == 4 ? 'Confirm your PIN' : 'Confirm your $shortLabel';
    }
    if (isPattern) return 'Draw your pattern again';
    return 'Confirm your password';
  }

  String get confirmDescription {
    if (isPin) return 'Re-enter your PIN to make sure it matches.';
    if (isPattern) return 'Draw the same pattern again to confirm it.';
    return 'Enter the same password again to confirm it.';
  }

  /// Copy used when changing the credential from Settings.
  String get changeHeading {
    if (isPin) return 'Enter current PIN';
    if (isPattern) return 'Draw your current pattern';
    return 'Enter current password';
  }

  String get changeDescription {
    if (isPin) return 'Verify your current PIN before choosing a new one.';
    if (isPattern) {
      return 'Verify your current pattern before choosing a new one.';
    }
    return 'Verify your current password before choosing a new one.';
  }

  /// Copy for the new-credential step after the current one was verified.
  String get newCredentialHeading {
    if (isPin) return pinLength == 4 ? 'Create new PIN' : 'Create new $shortLabel';
    if (isPattern) return 'Draw new pattern';
    return 'Create new password';
  }

  String get newCredentialDescription {
    if (isPin) return 'Choose a new $shortLabel for your apps.';
    if (isPattern) return 'Draw a new pattern. Connect at least 4 dots.';
    return 'Choose a new password. Letters, numbers and symbols are allowed.';
  }

  String get newConfirmHeading {
    if (isPin) return 'Confirm new PIN';
    if (isPattern) return 'Draw new pattern again';
    return 'Confirm new password';
  }

  String get newConfirmDescription {
    if (isPin) return 'Re-enter your new PIN to confirm it.';
    if (isPattern) return 'Draw the new pattern again to confirm it.';
    return 'Enter the new password again to confirm it.';
  }

  String get mismatchMessage {
    if (isPin) return "PINs don't match. Try again.";
    if (isPattern) return "Patterns don't match. Try again.";
    return "Passwords don't match. Try again.";
  }

  String get sameCredentialMessage =>
      'New $credentialNoun must be different from the current $credentialNoun.';

  String get saveErrorMessage {
    if (isPin) return 'Could not save your PIN. Please try again.';
    if (isPattern) return 'Could not save your pattern. Please try again.';
    return 'Could not save your password. Please try again.';
  }
}
