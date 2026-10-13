import 'package:flutter/material.dart';

import '../../../shared/widgets/pin_entry_panel.dart';
import '../../../shared/widgets/branding.dart';
import '../../../core/theme/app_theme.dart';

/// Screen C: create a new 4-digit PIN. Validates format and continues to
/// confirmation.
class CreatePinScreen extends StatefulWidget {
  const CreatePinScreen({super.key, required this.onPinCreated});

  final ValueChanged<String> onPinCreated;

  @override
  State<CreatePinScreen> createState() => _CreatePinScreenState();
}

class _CreatePinScreenState extends State<CreatePinScreen> {
  final _panelKey = GlobalKey<PinEntryPanelState>();

  void _onCompleted(String pin) {
    widget.onPinCreated(pin);
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
                heading: 'Create your PIN',
                description:
                    'This 4-digit PIN will unlock your protected apps.',
                actionLabel: 'Continue',
                onCompleted: _onCompleted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
