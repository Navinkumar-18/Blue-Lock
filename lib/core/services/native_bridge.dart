import 'dart:convert';

import 'package:flutter/services.dart';

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
      Uint8List? icon;
      final iconB64 = map['icon'] as String?;
      if (iconB64 != null && iconB64.isNotEmpty) {
        try {
          icon = base64Decode(iconB64);
        } catch (_) {
          icon = null;
        }
      }
      apps.add(InstalledApp(
        packageName: packageName,
        label: label,
        iconBytes: icon,
        isSystem: map['isSystem'] as bool? ?? false,
      ));
    }
    return apps;
  }

  Future<InstalledApp?> getAppInfo(String packageName) async {
    final raw = await _invoke<Map<dynamic, dynamic>>('getAppInfo', packageName);
    if (raw == null) return null;
    final map = Map<String, dynamic>.from(raw);
    Uint8List? icon;
    final iconB64 = map['icon'] as String?;
    if (iconB64 != null && iconB64.isNotEmpty) {
      try {
        icon = base64Decode(iconB64);
      } catch (_) {
        icon = null;
      }
    }
    return InstalledApp(
      packageName: map['package'] as String? ?? packageName,
      label: map['label'] as String? ?? packageName,
      iconBytes: icon,
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
}
