import 'dart:convert';

import 'package:flutter/services.dart';

import '../../features/app_lock/services/biometric_status.dart';
import '../../features/installed_apps/models/installed_app.dart';

/// Bridge to the native Android implementation (MainActivity).
///
/// Channel: com.bluelock.app/native
class NativeBridge {
  static const MethodChannel channel = MethodChannel('com.bluelock.app/native');

  /// True when the platform channel is reachable (real device/emulator).
  bool available = true;

  Future<T?> _invoke<T>(String method, [dynamic arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      available = false;
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Icon payload from native: raw PNG bytes (current protocol) or a
  /// Base64 string (kept for compatibility with older payloads).
  static Uint8List? decodeIcon(dynamic raw) {
    if (raw is Uint8List) return raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        return base64Decode(raw);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<List<InstalledApp>> getInstalledApps() async {
    final raw = await _invoke<List<dynamic>>('getInstalledApps');
    if (raw == null) return const [];
    final apps = <InstalledApp>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final packageName = map['package'] as String?;
      final label = map['label'] as String?;
      if (packageName == null || label == null) continue;
      apps.add(InstalledApp(
        packageName: packageName,
        label: label,
        iconBytes: decodeIcon(map['icon']),
        isSystem: map['isSystem'] as bool? ?? false,
      ));
    }
    return apps;
  }

  Future<InstalledApp?> getAppInfo(String packageName) async {
    final raw = await _invoke<Map<dynamic, dynamic>>('getAppInfo', packageName);
    if (raw == null) return null;
    final map = Map<String, dynamic>.from(raw);
    return InstalledApp(
      packageName: map['package'] as String? ?? packageName,
      label: map['label'] as String? ?? packageName,
      iconBytes: decodeIcon(map['icon']),
      isSystem: map['isSystem'] as bool? ?? false,
    );
  }

  Future<bool> hasUsageAccess() async {
    final result = await _invoke<bool>('hasUsageAccess');
    return result ?? false;
  }

  Future<void> openUsageAccessSettings() =>
      _invoke<void>('openUsageAccessSettings');

  Future<bool> hasOverlayPermission() async {
    final result = await _invoke<bool>('hasOverlayPermission');
    return result ?? false;
  }

  Future<void> openOverlaySettings() => _invoke<void>('openOverlaySettings');

  Future<void> setProtectedPackages(List<String> packages) =>
      _invoke<void>('setProtectedPackages', packages);

  Future<void> setLockEnabled(bool enabled) =>
      _invoke<void>('setLockEnabled', enabled);

  Future<void> setRelockTimeout(int seconds) =>
      _invoke<void>('setRelockTimeout', seconds);

  Future<void> lockPackage(String packageName) =>
      _invoke<void>('lockPackage', packageName);

  Future<void> unlockPackage(String packageName) =>
      _invoke<void>('unlockPackage', packageName);

  Future<bool> isPackageUnlocked(String packageName) async {
    final result = await _invoke<bool>('isPackageUnlocked', packageName);
    return result ?? false;
  }

  Future<String?> getForegroundPackage() async {
    return _invoke<String>('getForegroundPackage');
  }

  Future<BiometricStatus> getBiometricStatus() async {
    final raw = await _invoke<Map<dynamic, dynamic>>('getBiometricStatus');
    return BiometricStatus.fromMap(raw);
  }

  Future<void> setBiometricEnabled(bool enabled) =>
      _invoke<void>('setBiometricEnabled', enabled);

  // ---- Blue Lock self-authentication (app-entry gate) ----
  //
  // Sessions live in native LockPrefs keyed by our own package name, so they
  // never collide with third-party protected-app sessions and keep working
  // while Flutter is backgrounded (elapsed-time based expiry on the native
  // side, not a Dart timer).

  /// Whether Blue Lock's own unlock session is currently valid.
  Future<bool> isSelfUnlocked() async =>
      await _invoke<bool>('isSelfUnlocked') ?? false;

  /// Records a successful Blue Lock authentication under the relock policy.
  Future<void> unlockSelf() => _invoke<void>('unlockSelf');

  /// Expires Blue Lock's own unlock session (forgot-PIN reset, recovery).
  Future<void> lockSelf() => _invoke<void>('lockSelf');

  /// Blue Lock left the foreground: immediate policy expires the session,
  /// timed policies start the configured countdown from this moment.
  Future<void> onSelfBackgrounded() => _invoke<void>('selfBackgrounded');

  /// Launches the AndroidX system biometric prompt for Blue Lock itself.
  /// Returns the same outcome vocabulary as the lock screen:
  ///  - 'success'     platform-reported authentication success
  ///  - 'user_cancel' user dismissed the prompt / chose PIN
  ///  - 'unavailable' no biometrics, busy, or running outside Android
  ///  - 'failed'      any other platform error (never treated as success)
  Future<String> authenticateBiometricSelf({required String label}) async {
    try {
      final ok = await channel.invokeMethod<bool>('authenticateBiometric', {
        'package': 'com.bluelock.app',
        'label': label,
      });
      return ok == true ? 'success' : 'failed';
    } on MissingPluginException {
      available = false;
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
