import 'package:flutter/material.dart';

import '../../../shared/widgets/pin_entry_panel.dart';
import '../../../shared/widgets/branding.dart';
import '../../../core/theme/app_theme.dart';
import '../services/pin_service.dart';

/// Returning-user PIN verification from onboarding ("I already have a PIN").
class EnterPinScreen extends StatefulWidget {
  const EnterPinScreen({
    super.key,
    required this.pinService,
    required this.onVerified,
  });

  final PinService pinService;
  final VoidCallback onVerified;

  @override
  State<EnterPinScreen> createState() => _EnterPinScreenState();
}

class _EnterPinScreenState extends State<EnterPinScreen> {
  final _panelKey = GlobalKey<PinEntryPanelState>();
  bool _checking = false;

  Future<void> _onCompleted(String pin) async {
    if (_checking) return;
    setState(() => _checking = true);
    bool ok;
    try {
      ok = await widget.pinService.verifyPin(pin);
    } catch (_) {
      // Storage/crypto failure - do not report it as an incorrect PIN.
      if (!mounted) return;
      setState(() => _checking = false);
      _panelKey.currentState
          ?.showError('Could not verify your PIN. Try again.');
      return;
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (ok) {
      widget.onVerified();
    } else {
      _panelKey.currentState?.showError('Incorrect PIN. Try again.');
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
                heading: 'Enter your PIN',
                description: 'Verify your PIN to continue to Blue Lock.',
                actionLabel: _checking ? 'Checking...' : 'Continue',
                onCompleted: _onCompleted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
