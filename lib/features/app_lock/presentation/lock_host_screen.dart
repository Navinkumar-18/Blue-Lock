import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/perf_log.dart';
import '../presentation/app_lock_screen.dart';

/// Hosts the third-party app-lock authentication UI inside the engine booted
/// by the native LockActivity.
///
/// Two boot paths:
///  - Cold: LockActivity starts a fresh engine with initial route
///    `lock/<package>`; [initialPackage] is non-null and the PIN screen
///    renders immediately.
///  - Warm: LockActivity attaches the process-wide pre-warmed cached engine
///    (see LockEngineCache on the native side). That engine booted with the
///    bare "lock/" route, so this widget starts as an idle placeholder and
///    LockActivity pushes the protected package over the lock channel
///    ("showLock"). The PIN screen then replaces the placeholder in the next
///    frame - no engine or Dart cold start on the authentication path.
class LockHostScreen extends StatefulWidget {
  const LockHostScreen({
    super.key,
    required this.controller,
    this.initialPackage,
  });

  final AppController controller;

  /// Package from the native initial route; null on the warm idle boot.
  final String? initialPackage;

  @override
  State<LockHostScreen> createState() => LockHostScreenState();
}

class LockHostScreenState extends State<LockHostScreen> {
  static const MethodChannel _channel = MethodChannel('com.bluelock.app/lock');

  String? _package;

  /// Bumped on every show/clear so AppLockScreen fully remounts per session:
  /// while the engine is detached between lock activities no frames run, so
  /// an intermediate idle rebuild cannot separate two shows of the same
  /// package - the generation in the key does.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _package = widget.initialPackage;
    PerfLog.mark('lock-host: initState pkg=${_package ?? '(idle)'}');
    _channel.setMethodCallHandler(_onMethodCall);
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'showLock':
        final pkg = call.arguments as String?;
        if (pkg != null && pkg.isNotEmpty && mounted) {
          PerfLog.mark('lock-host: showLock $pkg');
          setState(() {
            _package = pkg;
            _generation++;
          });
        }
      case 'clearLock':
        if (mounted && _package != null) {
          PerfLog.mark('lock-host: clearLock');
          setState(() {
            _package = null;
            _generation++;
          });
        }
      default:
        throw MissingPluginException();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pkg = _package;
    if (pkg == null) {
      // Idle placeholder for the cached engine between lock sessions.
      // Matches the lock starting-window background so the attach frame and
      // the first showLock frame do not flash a different color.
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Icon(
            Icons.lock_rounded,
            size: 48,
            color: AppColors.primary,
          ),
        ),
      );
    }
    // ValueKey with generation: every showLock (and package retarget)
    // remounts AppLockScreen so PIN entry state, error banners and the
    // biometric prompt lifecycle start clean per lock session.
    // A back press must never pop the lock route and let Flutter's root
    // navigator call SystemNavigator.pop() (which finishes LockActivity and
    // briefly reveals the protected app). Dialogs pushed above this route
    // still pop normally.
    return PopScope(
      canPop: false,
      child: AppLockScreen(
        key: ValueKey('$pkg#$_generation'),
        packageName: pkg,
        controller: widget.controller,
        nativeLock: true,
      ),
    );
  }
}
