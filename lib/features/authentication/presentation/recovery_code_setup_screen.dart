import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/authentication/recovery_code.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';

/// Generates and displays the recovery code. It is shown exactly once.
///
/// The plaintext code exists only in this widget's memory; [AppStorage] keeps
/// a PBKDF2 verifier. The screen is used both after first-run setup and from
/// Settings for existing installations that never received a recovery code.
class RecoveryCodeSetupScreen extends StatefulWidget {
  const RecoveryCodeSetupScreen({
    super.key,
    required this.controller,
    this.isFirstRun = false,
    this.onFinished,
  });

  final AppController controller;

  /// First-run setup has no dashboard underneath yet; finishing navigates on
  /// instead of popping, and back is disabled to avoid a blank route.
  final bool isFirstRun;

  /// Called instead of popping when set.
  final VoidCallback? onFinished;

  @override
  State<RecoveryCodeSetupScreen> createState() =>
      _RecoveryCodeSetupScreenState();
}

class _RecoveryCodeSetupScreenState extends State<RecoveryCodeSetupScreen> {
  String? _code;
  String? _error;
  bool _generating = true;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final code = await widget.controller.recoveryService.createRecoveryCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _generating = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _error = 'Could not create a recovery code. Please try again.';
      });
    }
  }

  void _finish() {
    final onFinished = widget.onFinished;
    if (onFinished != null) {
      onFinished();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _copy() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: RecoveryCode.format(code)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recovery code copied. Store it somewhere safe.'),
      ),
    );
  }

  Future<void> _skip() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Continue without a recovery code?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        content: const Text(
          'If you forget your lock, enrolled biometrics would be the only '
          'in-app way back in. Otherwise you would have to clear Blue Lock\'s '
          'app data in Android Settings, which removes your protected-app '
          'list and settings.',
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Go back'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Continue anyway',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _finish();
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: !widget.isFirstRun,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: widget.isFirstRun
            ? null
            : AppBar(
                title: const Text('Recovery code'),
                leading: const BackButton(color: AppColors.textPrimary),
              ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + keyboard),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.isFirstRun) ...[
                  const SizedBox(height: 12),
                  const Center(child: AppLogo(size: 64)),
                  const SizedBox(height: 22),
                ],
                const Text(
                  'Save your recovery code',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Use this code if you forget your lock. It is shown only '
                  'once, so write it down and keep it somewhere safe.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 22),
                _buildCodeArea(),
                const SizedBox(height: 18),
                const _WarningNote(),
                const SizedBox(height: 22),
                if (_error == null && _code != null)
                  PrimaryButton(
                    label: 'I\'ve saved my recovery code',
                    icon: Icons.check_rounded,
                    onPressed: _finish,
                  ),
                const SizedBox(height: 6),
                if (!_generating && _error != null)
                  PrimaryButton(label: 'Try again', onPressed: _generate),
                if (widget.isFirstRun && !_generating)
                  TextButton(
                    onPressed: _skip,
                    child: const Text(
                      'Skip for now',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCodeArea() {
    if (_generating) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return BlueLockCard(
        padding: const EdgeInsets.all(18),
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.danger,
          ),
        ),
      );
    }
    final code = _code!;
    return BlueLockCard(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
      child: Column(
        children: [
          const Text(
            'YOUR RECOVERY CODE',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          // Scale rather than overflow: narrow screens and large text-scale
          // settings must still show the whole code, and system fonts can be
          // wider than the default. The copy button offers select-free export.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Semantics(
              label: 'Recovery code displayed on screen',
              child: Text(
                RecoveryCode.format(code),
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  fontSize: 22,
                  height: 1.4,
                  letterSpacing: 2.2,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _copy,
            icon: const Icon(
              Icons.copy_rounded,
              size: 18,
              color: AppColors.primary,
            ),
            label: const Text(
              'Copy code',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningNote extends StatelessWidget {
  const _WarningNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x33D97706)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 20, color: AppColors.warning),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Blue Lock stores only a verifier, so it cannot show or recover '
              'this code later. If you lose it, enrolled biometrics is the '
              'only in-app recovery; otherwise Android Settings app-data '
              'clearing is required and removes all Blue Lock settings.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
