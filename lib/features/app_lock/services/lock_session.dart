import 'package:flutter/services.dart';

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
}
