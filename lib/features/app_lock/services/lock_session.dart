import 'package:flutter/services.dart';

import 'biometric_status.dart';

/// Shared constants for the app-lock session bridge.
class LockSession {
  LockSession._();

  /// Own application id - never lock ourselves (prevents locking loops).
  static const String selfPackage = 'com.bluelock.app';

  static const MethodChannel channel = MethodChannel('com.bluelock.app/lock');

  /// Ask native code to record a successful unlock and dismiss the lock
  /// activity.
  static Future<void> unlock(String packageName) async {
    try {
      await channel.invokeMethod('unlock', packageName);
    } on MissingPluginException {
      // Running outside the lock activity (tests / preview).
    } on PlatformException {
      // Ignore - unlock recording is best-effort.
    }
  }

  /// Forgot-PIN recovery: wipes PIN and protected apps (personal-use reset).
  /// The original PIN cannot be recovered.
  static Future<void> resetProtection() async {
    try {
      await channel.invokeMethod('resetProtection');
    } on MissingPluginException {
      // Ignore outside lock activity.
    } on PlatformException {
      // Ignore.
    }
  }

  /// Device biometric capability + user preference (via the lock channel).
  static Future<BiometricStatus> biometricStatus() async {
    try {
      final raw = await channel.invokeMethod<dynamic>('getBiometricStatus');
      return BiometricStatus.fromMap(raw is Map ? raw : null);
    } on MissingPluginException {
      return BiometricStatus.unavailable;
    } on PlatformException {
      return BiometricStatus.unavailable;
    }
  }

  /// Launches the system biometric prompt. Returns:
  ///  - 'success'     platform-reported authentication success
  ///  - 'user_cancel' user dismissed the prompt / chose PIN
  ///  - 'unavailable' no biometrics, busy, or running outside LockActivity
  ///  - 'failed'      any other platform error (never treated as success)
  static Future<String> authenticateBiometric({
    required String packageName,
    required String label,
  }) async {
    try {
      final ok = await channel.invokeMethod<bool>('authenticateBiometric', {
        'package': packageName,
        'label': label,
      });
      return ok == true ? 'success' : 'failed';
    } on MissingPluginException {
      return 'unavailable';
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'user_cancel':
          return 'user_cancel';
        case 'unavailable':
        case 'busy':
          return 'unavailable';
        default:
          return 'failed';
      }
    }
  }
}
