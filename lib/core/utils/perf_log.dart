import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Development-only timing marks for locating slow transitions.
///
/// Prints milliseconds elapsed since the first mark (app start). Logs
/// durations only - never PINs, hashes, salts or other authentication
/// secrets. Compiled out of release builds, so release performance is
/// unaffected; debug and profile builds emit:
///  - named milestone marks via [mark]
///  - one line per frame via the frame watch ([startFrameWatch])
/// which device-side measurement scripts can scrape from logcat.
class PerfLog {
  PerfLog._();

  static final Stopwatch _clock = Stopwatch()..start();

  /// Elapsed milliseconds for named milestones (null until marked).
  static int? markMs;
  static int? homeFrameMs;

  /// Frame-budget accounting (device measurement).
  static bool _watching = false;
  static int _frames = 0;
  static int _janky = 0;
  static int _worstBuildUs = 0;
  static int _worstRasterUs = 0;
  static int _windowFrames = 0;
  static int _windowJanky = 0;
  static int _windowWorstBuildUs = 0;
  static int _windowWorstRasterUs = 0;
  static String _phase = 'run';

  static bool get _enabled => !kReleaseMode;

  static void mark(String label) {
    if (!_enabled) return;
    final elapsed = _clock.elapsedMilliseconds;
    debugPrint('[perf] +${elapsed}ms $label');
    switch (label) {
      case 'confirm: fourth digit accepted':
        markMs = elapsed;
      case 'home: first frame':
        homeFrameMs = elapsed;
    }
  }

  /// Names the current measurement phase; summaries are tagged with it so a
  /// logcat scrape can attribute frames to dashboard / list scroll / search.
  static void phase(String name) {
    if (!_enabled) return;
    if (_frames > 0) _printSummary(tag: 'phase-end');
    _phase = name;
    _frames = 0;
    _janky = 0;
    _worstBuildUs = 0;
    _worstRasterUs = 0;
    _windowFrames = 0;
    _windowJanky = 0;
    _windowWorstBuildUs = 0;
    _windowWorstRasterUs = 0;
    debugPrint('[perf] +${_clock.elapsedMilliseconds}ms phase: $name');
  }

  /// Starts per-frame timing capture (debug and profile builds only).
  static void startFrameWatch() {
    if (_watching || !_enabled) return;
    _watching = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  static void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final buildUs = timing.buildDuration.inMicroseconds;
      final rasterUs = timing.rasterDuration.inMicroseconds;
      _frames++;
      _windowFrames++;
      if (buildUs > _worstBuildUs) _worstBuildUs = buildUs;
      if (rasterUs > _worstRasterUs) _worstRasterUs = rasterUs;
      if (buildUs > _windowWorstBuildUs) _windowWorstBuildUs = buildUs;
      if (rasterUs > _windowWorstRasterUs) _windowWorstRasterUs = rasterUs;
      // 60 Hz budget = 16.7 ms per stage; anything above misses a frame.
      if (buildUs > 16667 || rasterUs > 16667) {
        _janky++;
        _windowJanky++;
        debugPrint(
          '[perf] +${_clock.elapsedMilliseconds}ms jank phase=$_phase '
          'build=${(buildUs / 1000).toStringAsFixed(1)} '
          'raster=${(rasterUs / 1000).toStringAsFixed(1)}',
        );
      }
      if (_windowFrames >= 60) {
        _printWindowSummary();
      }
    }
  }

  static void _printWindowSummary() {
    debugPrint(
      '[perf] +${_clock.elapsedMilliseconds}ms window phase=$_phase '
      'n=$_windowFrames janky=$_windowJanky '
      'worstBuild=${(_windowWorstBuildUs / 1000).toStringAsFixed(1)} '
      'worstRaster=${(_windowWorstRasterUs / 1000).toStringAsFixed(1)}',
    );
    _windowFrames = 0;
    _windowJanky = 0;
    _windowWorstBuildUs = 0;
    _windowWorstRasterUs = 0;
  }

  static void _printSummary({required String tag}) {
    debugPrint(
      '[perf] +${_clock.elapsedMilliseconds}ms $tag phase=$_phase '
      'n=$_frames janky=$_janky '
      'worstBuild=${(_worstBuildUs / 1000).toStringAsFixed(1)} '
      'worstRaster=${(_worstRasterUs / 1000).toStringAsFixed(1)}',
    );
  }
}
