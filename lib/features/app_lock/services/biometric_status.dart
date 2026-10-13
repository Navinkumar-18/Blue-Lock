/// Device biometric capability, reported by the native side.
class BiometricStatus {
  const BiometricStatus({
    required this.available,
    required this.enrolled,
    required this.enabled,
  });

  /// Hardware present and at least one biometric enrolled.
  final bool available;
  final bool enrolled;

  /// User preference: offer biometric unlock on the lock screen.
  final bool enabled;

  /// Biometrics may actually be offered right now.
  bool get canUse => available && enrolled && enabled;

  static const unavailable = BiometricStatus(
    available: false,
    enrolled: false,
    enabled: false,
  );

  factory BiometricStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return unavailable;
    return BiometricStatus(
      available: map['available'] as bool? ?? false,
      enrolled: map['enrolled'] as bool? ?? false,
      enabled: map['enabled'] as bool? ?? true,
    );
  }
}
