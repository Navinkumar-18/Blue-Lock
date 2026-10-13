import 'package:flutter/material.dart';

import '../../../shared/widgets/pin_entry_panel.dart';
import '../../../shared/widgets/branding.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/perf_log.dart';

/// Screen D: confirm the PIN entered during creation. Mismatched PINs are
/// rejected with feedback and the user can try again.
class ConfirmPinScreen extends StatefulWidget {
  const ConfirmPinScreen({
    super.key,
    required this.firstPin,
    required this.onConfirmed,
  });

  final String firstPin;

  /// Persists the confirmed PIN and navigates to the dashboard. Invoked at
  /// most once per confirmation; an error leaves the user on this screen.
  final Future<void> Function(String pin) onConfirmed;

  @override
  State<ConfirmPinScreen> createState() => _ConfirmPinScreenState();
}

class _ConfirmPinScreenState extends State<ConfirmPinScreen> {
  final _panelKey = GlobalKey<PinEntryPanelState>();
  String? _error;
  bool _busy = false;

  Future<void> _onCompleted(String pin) async {
    // Guard against duplicate submissions: the panel auto-fires on the
    // fourth digit and the action button stays tappable while processing.
    if (_busy) return;
    if (pin != widget.firstPin) {
      setState(() => _error = "PINs don't match. Try again.");
      _panelKey.currentState?.showError("PINs don't match. Try again.");
      return;
    }
    PerfLog.mark('confirm: fourth digit accepted');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirmed(pin);
      // Success: navigation in onConfirmed replaces this screen.
    } catch (e) {
      PerfLog.mark('confirm: setup failed (${e.runtimeType})');
      if (!mounted) return;
      setState(() => _busy = false);
      _panelKey.currentState
          ?.showError('Could not save your PIN. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            children: [
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: BackButton(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              const AppLogo(size: 64),
              const SizedBox(height: 24),
              PinEntryPanel(
                key: _panelKey,
                heading: 'Confirm your PIN',
                description: 'Re-enter your PIN to make sure it matches.',
                actionLabel: _busy ? 'Saving...' : 'Confirm',
                errorText: _error,
                onCompleted: _onCompleted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
