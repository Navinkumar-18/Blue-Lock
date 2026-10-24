import 'dart:async';

import 'package:flutter/services.dart';

import 'biometric_status.dart';

/// Shared constants for the app-lock session bridge.
class LockSession {
  LockSession._();

  /// Own application id - never lock ourselves (prevents locking loops).
  static const String selfPackage = 'com.bluelock.app';

  static const MethodChannel channel = MethodChannel('com.bluelock.app/lock');

  /// Outer bound for a single system-prompt round trip. Native code answers
  /// every request itself (AndroidX callback, watchdog or host teardown), so
  /// this only guards a platform hang that would otherwise leave the
  /// biometric button disabled forever. The system prompt auto-dismisses
  /// well before this and the native watchdog fires at 60s.
  static const Duration biometricCallTimeout = Duration(seconds: 75);

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

  /// Ask native code to record a successful unlock for one Instagram
  /// conversation. The app-level session is deliberately not granted here.
  static Future<void> unlockChat({
    required String packageName,
    required String username,
  }) async {
    try {
      await channel.invokeMethod('unlock', <String, String>{
        'package': packageName,
        'chat': username,
      });
    } on MissingPluginException {
      // Running outside the lock activity (tests / preview).
    } on PlatformException {
      // Ignore - unlock recording is best-effort.
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
  ///  - 'success'            platform-reported authentication success
  ///  - 'user_cancel'        user dismissed the prompt / chose PIN
  ///  - 'lockout'            temporary platform lockout; PIN is the fallback
  ///  - 'lockout_permanent'  too many attempts; device unlock re-enables it
  ///  - 'unavailable'        no biometrics, busy, or outside LockActivity
  ///  - 'failed'             any other platform error (never treated as success)
  static Future<String> authenticateBiometric({
    required String packageName,
    required String label,
  }) async {
    try {
      final ok = await channel
          .invokeMethod<bool>('authenticateBiometric', {
            'package': packageName,
            'label': label,
          })
          .timeout(biometricCallTimeout);
      return ok == true ? 'success' : 'failed';
    } on TimeoutException {
      return 'failed';
    } on MissingPluginException {
      return 'unavailable';
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'user_cancel':
          return 'user_cancel';
        case 'lockout':
          return 'lockout';
        case 'lockout_permanent':
          return 'lockout_permanent';
        case 'unavailable':
        case 'busy':
          return 'unavailable';
        default:
          return 'failed';
      }
    }
  }

  /// Records that the first usable authentication screen is displayed.
  /// Native LockActivity logs the total elapsed time from the trigger.
  static Future<void> markUsable() async {
    try {
      await channel.invokeMethod('markUsable');
    } on MissingPluginException {
      // Ignored outside lock activity.
    } on PlatformException {
      // Ignored.
    }
  }
}
