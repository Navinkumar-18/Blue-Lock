import '../../../core/services/native_bridge.dart';
import '../models/installed_app.dart';

/// Loads real installed, launchable applications through native Android.
class AppsRepository {
  AppsRepository(this._native);

  final NativeBridge _native;

  Future<List<InstalledApp>> getInstalledApps() async {
    final apps = await _native.getInstalledApps();
    if (apps.length <= 1) return apps;
    // Decorate-sort-undecorate: one toLowerCase per app instead of two per
    // comparison during the sort.
    final decorated = <MapEntry<String, InstalledApp>>[
      for (final app in apps) MapEntry(app.label.toLowerCase(), app),
    ]..sort((a, b) => a.key.compareTo(b.key));
    return [for (final entry in decorated) entry.value];
  }

  Future<InstalledApp?> getAppInfo(String packageName) =>
      _native.getAppInfo(packageName);
}
