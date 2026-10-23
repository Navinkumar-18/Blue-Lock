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
  _Step _step = _Step.verifyCurrent;
  String? _currentPin;
  String? _newPin;
  bool _busy = false;
  String? _error;

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
        setState(() {
          _busy = true;
          _error = null;
        });
        PinVerification result;
        try {
          result = await widget.pinService.verifyPinDetailed(pin);
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = 'Could not verify your PIN. Please try again.';
          });
          return;
        }
        if (!mounted) return;
        if (result.isSuccess) {
          setState(() {
            _busy = false;
            _currentPin = pin;
            _step = _Step.newPin;
            _error = null;
          });
        } else {
          setState(() {
            _busy = false;
            _error = result.message;
          });
        }

      case _Step.newPin:
        if (_currentPin != null && pin == _currentPin) {
          setState(() {
            _busy = false;
            _error = 'New PIN must be different from the current PIN.';
          });
          return;
        }
        setState(() {
          _busy = false;
          _newPin = pin;
          _step = _Step.confirmNew;
          _error = null;
        });

      case _Step.confirmNew:
        if (pin != _newPin) {
          setState(() {
            _busy = false;
            _error = "PINs don't match. Try again.";
          });
          return;
        }
        setState(() {
          _busy = true;
          _error = null;
        });
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
          setState(() {
            _busy = false;
            _error = e.message;
          });
        } catch (_) {
          // Storage or crypto failure while persisting the new verifier.
          // Never report success if persistence fails. Always restore busy state.
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = 'Could not save your PIN. Please try again.';
          });
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
            key: ValueKey(_step),
            heading: _heading,
            description: _description,
            actionLabel: _actionLabel,
            errorText: _error,
            onInputChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onCompleted: _onCompleted,
          ),
        ),
      ),
    );
  }
}

enum _Step { verifyCurrent, newPin, confirmNew }
