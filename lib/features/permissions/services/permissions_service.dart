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
}
