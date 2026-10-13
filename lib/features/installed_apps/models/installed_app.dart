import 'dart:typed_data';

class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    this.iconBytes,
    this.isSystem = false,
  });

  final String packageName;
  final String label;
  final Uint8List? iconBytes;
  final bool isSystem;

  InstalledApp copyWith({Uint8List? iconBytes}) => InstalledApp(
        packageName: packageName,
        label: label,
        iconBytes: iconBytes ?? this.iconBytes,
        isSystem: isSystem,
      );
}
