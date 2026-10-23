import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/authentication/credential_rules.dart';
import '../../core/theme/app_theme.dart';
import 'buttons.dart';

/// Interactive 3 x 3 pattern lock.
///
/// Supports both drag drawing (the primary interaction) and tapping dots
/// (useful with accessibility switches and widget tests). A dot can never be
/// added twice to the same pattern, and lifting the finger submits only when
/// at least four different dots are selected.
class PatternLockPanel extends StatefulWidget {
  const PatternLockPanel({
    super.key,
    required this.heading,
    required this.description,
    required this.actionLabel,
    required this.onCompleted,
    this.errorText,
    this.forgotLabel,
    this.onForgot,
    this.showAction = true,
  });

  final String heading;
  final String description;
  final String actionLabel;
  final ValueChanged<List<int>> onCompleted;
  final String? errorText;
  final String? forgotLabel;
  final VoidCallback? onForgot;
  final bool showAction;

  @override
  State<PatternLockPanel> createState() => PatternLockPanelState();
}

class PatternLockPanelState extends State<PatternLockPanel> {
  final List<int> _dots = <int>[];
  Offset? _pointer;
  String? _localError;

  /// Latched while a verification round trip is running so one gesture can
  /// never submit the same pattern twice.
  bool _submitted = false;

  double _dimension = 280;
  double _padding = 28;

  List<int> get dots => List<int>.unmodifiable(_dots);

  @override
  void didUpdateWidget(covariant PatternLockPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorText != null && widget.errorText != oldWidget.errorText) {
      _reset();
    }
  }

  void clear() => _reset();

  void showError(String message) {
    setState(() {
      _dots.clear();
      _pointer = null;
      _localError = message;
      _submitted = false;
    });
  }

  void _reset() {
    setState(() {
      _dots.clear();
      _pointer = null;
      _localError = null;
      _submitted = false;
    });
  }

  static const int _grid = CredentialRules.patternGridSize;

  Offset _dotPosition(int dot) {
    final usable = _dimension - _padding * 2;
    final step = usable / (_grid - 1);
    final row = dot ~/ _grid;
    final col = dot % _grid;
    return Offset(_padding + col * step, _padding + row * step);
  }

  int? _hitTest(Offset local) {
    final hitRadius = ((_dimension - _padding * 2) / (_grid - 1)) * 0.46;
    var bestDistance = double.infinity;
    int? best;
    for (var i = 0; i < CredentialRules.patternDotCount; i++) {
      final distance = (local - _dotPosition(i)).distance;
      if (distance <= hitRadius && distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  void _addAt(Offset local) {
    if (_submitted) return;
    final hit = _hitTest(local);
    if (hit == null || _dots.contains(hit)) return;
    setState(() {
      _dots.add(hit);
      _localError = null;
    });
  }

  void _onPanStart(DragStartDetails details) {
    if (_submitted) return;
    setState(() => _pointer = details.localPosition);
    _addAt(details.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_submitted) return;
    setState(() => _pointer = details.localPosition);
    _addAt(details.localPosition);
  }

  void _onPanEnd(DragEndDetails details) {
    if (_submitted) return;
    setState(() => _pointer = null);
    if (_dots.length >= CredentialRules.minPatternDots) {
      _submit();
    } else if (_dots.isNotEmpty && _localError == null) {
      setState(() {
        _localError =
            'Connect at least ${CredentialRules.minPatternDots} dots.';
      });
    }
  }

  void _onTapUp(TapUpDetails details) {
    _addAt(details.localPosition);
  }

  void _submit() {
    if (_submitted) return;
    if (!CredentialRules.isValidPatternDots(_dots)) {
      setState(() {
        _localError =
            'Connect at least ${CredentialRules.minPatternDots} dots.';
      });
      return;
    }
    setState(() {
      _submitted = true;
      _pointer = null;
      _localError = null;
    });
    widget.onCompleted(List<int>.unmodifiable(_dots));
  }

  @override
  Widget build(BuildContext context) {
    final error = _localError ?? widget.errorText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          widget.heading,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.description,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            _dimension = math.min(
              constraints.maxWidth.isFinite ? constraints.maxWidth : 320,
              320,
            );
            _padding = _dimension * 0.1;
            return Semantics(
              container: true,
              liveRegion: true,
              label: 'Pattern lock. ${_dots.length} dots selected. '
                  'Draw at least ${CredentialRules.minPatternDots} dots.',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onTapUp,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: SizedBox(
                  width: _dimension,
                  height: _dimension,
                  child: CustomPaint(
                    painter: _PatternPainter(
                      dots: _dots,
                      pointer: _pointer,
                      dotPosition: _dotPosition,
                      error: error != null,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        SizedBox(
          height: 30,
          child: error == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.danger,
                    ),
                  ),
                ),
        ),
        if (widget.showAction)
          PrimaryButton(
            label: widget.actionLabel,
            enabled: _dots.length >= CredentialRules.minPatternDots &&
                !_submitted,
            onPressed: _submit,
          ),
        if (widget.forgotLabel != null && widget.onForgot != null)
          TextButton(
            onPressed: widget.onForgot,
            child: Text(
              widget.forgotLabel!,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({
    required this.dots,
    required this.pointer,
    required this.dotPosition,
    required this.error,
  });

  final List<int> dots;
  final Offset? pointer;
  final Offset Function(int dot) dotPosition;
  final bool error;

  @override
  void paint(Canvas canvas, Size size) {
    final color = error ? AppColors.danger : AppColors.primary;
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (var i = 1; i < dots.length; i++) {
      canvas.drawLine(
        dotPosition(dots[i - 1]),
        dotPosition(dots[i]),
        linePaint,
      );
    }
    if (pointer != null && dots.isNotEmpty) {
      canvas.drawLine(dotPosition(dots.last), pointer!, linePaint);
    }

    final radius = math.max(10.0, size.width * 0.045);
    for (var i = 0; i < CredentialRules.patternDotCount; i++) {
      final center = dotPosition(i);
      final selectedIndex = dots.indexOf(i);
      final selected = selectedIndex >= 0;
      canvas.drawCircle(
        center,
        radius + 2,
        Paint()
          ..color = selected ? color : AppColors.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      if (selected) {
        canvas.drawCircle(center, radius, Paint()..color = color);
        // A small dot inside the selected node keeps the order legible.
        canvas.drawCircle(
          center,
          radius * 0.32,
          Paint()..color = Colors.white,
        );
      } else {
        canvas.drawCircle(center, radius * 0.42, Paint()..color = AppColors.border);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter oldDelegate) {
    return !listEquals(oldDelegate.dots, dots) ||
        oldDelegate.pointer != pointer ||
        oldDelegate.error != error;
  }
}
