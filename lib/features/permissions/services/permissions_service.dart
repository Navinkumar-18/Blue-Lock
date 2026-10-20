import 'dart:io';

import '../../../core/services/native_bridge.dart';

/// Checks and opens system settings for the Android permissions Blue Lock
/// needs. Status is read from the OS - never faked.
class PermissionsService {
  PermissionsService(this._native);

  final NativeBridge _native;

  Future<bool> hasUsageAccess() => _native.hasUsageAccess();

  Future<void> openUsageAccessSettings() => _native.openUsageAccessSettings();

  Future<bool> hasOverlayPermission() => _native.hasOverlayPermission();

  Future<void> openOverlaySettings() => _native.openOverlaySettings();

  // ---- background-keepalive (Android 13+/battery) ----

  /// True when the protection notification is allowed to be shown (always
  /// true below Android 13 where no runtime permission exists).
  Future<bool> hasNotificationPermission() =>
      _native.hasNotificationPermission();

  Future<void> requestNotificationPermission() =>
      _native.requestNotificationPermission();

  /// True when Blue Lock is exempt from battery optimization.
  Future<bool> isIgnoringBatteryOptimizations() =>
      _native.isIgnoringBatteryOptimizations();

  /// System dialog asking the user to allow unrestricted battery usage.
  Future<void> requestIgnoreBatteryOptimizations() =>
      _native.requestIgnoreBatteryOptimizations();

  /// Battery-optimization list fallback.
  Future<void> openBatteryOptimizationSettings() =>
      _native.openBatteryOptimizationSettings();

  /// App-details page (Motorola's "Battery usage -> Unrestricted" lives here).
  Future<void> openAppSettings() => _native.openAppSettings();

  /// Whether the battery-optimization flow applies on this platform.
  bool get batteryGuidanceRelevant => Platform.isAndroid;
}
