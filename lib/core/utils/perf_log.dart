import 'package:flutter/foundation.dart';

/// Development-only timing marks for locating slow transitions.
///
/// Prints milliseconds elapsed since the first mark (app start). Logs
/// durations only - never PINs, hashes, salts or other authentication
/// secrets. Guarded by [kDebugMode] so release builds are unaffected.
class PerfLog {
  PerfLog._();

  static final Stopwatch _clock = Stopwatch()..start();

  /// Elapsed milliseconds for named milestones (null until marked).
  static int? markMs;
  static int? homeFrameMs;

  static void mark(String label) {
    if (!kDebugMode) return;
    final elapsed = _clock.elapsedMilliseconds;
    debugPrint('[perf] +${elapsed}ms $label');
    switch (label) {
      case 'confirm: fourth digit accepted':
        markMs = elapsed;
      case 'home: first frame':
        homeFrameMs = elapsed;
    }
  }
}
