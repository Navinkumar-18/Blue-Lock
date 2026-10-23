import 'authentication_type.dart';

/// A credential verifier as persisted in encrypted storage.
///
/// Only the type, salt and derived verifier are stored - never the PIN,
/// pattern or password itself. [isLegacy] marks a record read from the
/// pre-multi-type keys (`pin_salt` + raw `pin_verifier`), which always means a
/// four-digit PIN unless an older build had stored an explicit type.
class StoredCredential {
  const StoredCredential({
    required this.type,
    required this.saltB64,
    required this.verifierB64,
    this.isLegacy = false,
  });

  final AuthenticationType type;
  final String saltB64;
  final String verifierB64;
  final bool isLegacy;
}
