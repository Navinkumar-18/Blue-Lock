import 'package:flutter/material.dart';

import '../../../shared/widgets/pin_entry_panel.dart';
import '../../../core/theme/app_theme.dart';
import '../services/pin_service.dart';

/// Screen J: change the security PIN - verify current PIN, enter new PIN,
/// confirm new PIN. A successful change updates the stored verifier.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key, required this.pinService});

  final PinService pinService;

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  final _panelKey = GlobalKey<PinEntryPanelState>();
  _Step _step = _Step.verifyCurrent;
  String? _currentPin;
  String? _newPin;
  bool _busy = false;

  String get _heading => switch (_step) {
        _Step.verifyCurrent => 'Enter current PIN',
        _Step.newPin => 'Create new PIN',
        _Step.confirmNew => 'Confirm new PIN',
      };

  String get _description => switch (_step) {
        _Step.verifyCurrent =>
          'Verify your current PIN before choosing a new one.',
        _Step.newPin => 'Choose a new 4-digit PIN for your apps.',
        _Step.confirmNew => 'Re-enter your new PIN to confirm it.',
      };

  String get _actionLabel => switch (_step) {
        _Step.verifyCurrent => 'Continue',
        _Step.newPin => 'Continue',
        _Step.confirmNew => _busy ? 'Saving...' : 'Confirm',
      };

  Future<void> _onCompleted(String pin) async {
    if (_busy) return;
    switch (_step) {
      case _Step.verifyCurrent:
        setState(() => _busy = true);
        bool ok;
        try {
          ok = await widget.pinService.verifyPin(pin);
        } catch (_) {
          if (!mounted) return;
          setState(() => _busy = false);
          _panelKey.currentState
              ?.showError('Could not verify your PIN. Try again.');
          return;
        }
        if (!mounted) return;
        setState(() {
          _busy = false;
          if (ok) {
            _currentPin = pin;
            _step = _Step.newPin;
            _panelKey.currentState?.clear();
          }
        });
        if (!ok) {
          _panelKey.currentState?.showError('Incorrect PIN. Try again.');
        }
      case _Step.newPin:
        if (_currentPin != null && pin == _currentPin) {
          _panelKey.currentState
              ?.showError('New PIN must be different from the current PIN.');
          return;
        }
        setState(() {
          _newPin = pin;
          _step = _Step.confirmNew;
          _panelKey.currentState?.clear();
        });
      case _Step.confirmNew:
        if (pin != _newPin) {
          _panelKey.currentState?.showError("PINs don't match. Try again.");
          return;
        }
        setState(() => _busy = true);
        try {
          await widget.pinService.changePin(
            currentPin: _currentPin!,
            newPin: _newPin!,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('PIN updated successfully.'),
              backgroundColor: AppColors.success,
            ),
          );
          Navigator.of(context).pop(true);
        } on PinException catch (e) {
          if (!mounted) return;
          setState(() => _busy = false);
          _panelKey.currentState?.showError(e.message);
        } catch (_) {
          // Storage failure while persisting the new verifier.
          if (!mounted) return;
          setState(() => _busy = false);
          _panelKey.currentState
              ?.showError('Could not save your PIN. Please try again.');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Change PIN'),
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: PinEntryPanel(
            key: _panelKey,
            heading: _heading,
            description: _description,
            actionLabel: _actionLabel,
            onCompleted: _onCompleted,
          ),
        ),
      ),
    );
  }
}

enum _Step { verifyCurrent, newPin, confirmNew }
