import '../../../core/services/native_bridge.dart';
import '../models/installed_app.dart';

/// Loads real installed, launchable applications through native Android.
class AppsRepository {
  AppsRepository(this._native);

  final NativeBridge _native;

  Future<List<InstalledApp>> getInstalledApps() async {
    final apps = await _native.getInstalledApps();
    final sorted = List<InstalledApp>.from(apps)
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return sorted;
  }

  Future<InstalledApp?> getAppInfo(String packageName) =>
      _native.getAppInfo(packageName);
}
