import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/credential_entry_panel.dart';
import '../../../shared/widgets/credential_setup_panel.dart';
import 'choose_lock_type_screen.dart';

/// Settings flow: authenticate with the current method, choose a new method,
/// configure and confirm it, then atomically replace the verifier + type.
///
/// Nothing is written until the final confirmation, so cancelling at any
/// step leaves the existing credential untouched.
class ChangeLockTypeScreen extends StatefulWidget {
  const ChangeLockTypeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChangeLockTypeScreen> createState() => _ChangeLockTypeScreenState();
}

enum _Step { verifyCurrent, chooseType, configure }

class _ChangeLockTypeScreenState extends State<ChangeLockTypeScreen> {
  final GlobalKey<CredentialEntryPanelState> _verifyKey =
      GlobalKey<CredentialEntryPanelState>();
  _Step _step = _Step.verifyCurrent;
  String? _currentCredential;
  AuthenticationType? _newType;
  bool _busy = false;

  AuthenticationType get _currentType => widget.controller.authType;

  Future<void> _verify(String credential) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result =
          await widget.controller.pinService.verifyPinDetailed(credential);
      if (!mounted) return;
      if (result.isSuccess) {
        setState(() {
          _busy = false;
          _currentCredential = credential;
          _step = _Step.chooseType;
        });
      } else {
        setState(() => _busy = false);
        _verifyKey.currentState?.showError(result.message);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _verifyKey.currentState
          ?.showError('Could not verify your ${_currentType.credentialNoun}. '
              'Try again.');
    }
  }

  Future<void> _save(String credential) async {
    await widget.controller.replaceCredential(
      type: _newType!,
      credential: credential,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_newType!.title} saved.'),
        backgroundColor: AppColors.success,
      ),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Change lock type'),
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + keyboard),
          child: _buildStep(),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.verifyCurrent:
        final type = _currentType;
        return CredentialEntryPanel(
          key: _verifyKey,
          type: type,
          heading: type.changeHeading,
          description:
              'Verify your current ${type.credentialNoun} before choosing a '
              'new lock type.',
          actionLabel: _busy ? 'Checking...' : 'Continue',
          onCompleted: _verify,
          showAction: true,
        );
      case _Step.chooseType:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            const Text(
              'Choose your new lock type',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'You will configure and confirm the new credential next. Your '
              'current one stays active until the new one is saved.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 22),
            LockTypeOptionList(
              currentType: _currentType,
              onSelected: (type) => setState(() {
                _newType = type;
                _step = _Step.configure;
              }),
            ),
          ],
        );
      case _Step.configure:
        final type = _newType!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Set up your ${type.title}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 18),
            CredentialSetupPanel(
              type: type,
              currentCredential: _currentCredential,
              onConfirmed: _save,
            ),
          ],
        );
    }
  }
}
