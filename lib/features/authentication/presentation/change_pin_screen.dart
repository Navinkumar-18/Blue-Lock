import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/credential_entry_panel.dart';
import '../../../shared/widgets/credential_setup_panel.dart';
import '../services/pin_service.dart';

/// Change the current credential without changing its type.
///
/// The constructor deliberately keeps accepting a [PinService] so older
/// callers/tests continue to work. Change Lock Type is a separate flow.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key, required this.pinService});

  final PinService pinService;

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  final GlobalKey<CredentialEntryPanelState> _verifyKey =
      GlobalKey<CredentialEntryPanelState>();
  bool _verified = false;
  bool _busy = false;
  String? _currentCredential;

  AuthenticationType get _type => widget.pinService.authType;

  String get _title {
    if (_type.isPin) return 'Change PIN';
    if (_type.isPattern) return 'Change pattern';
    return 'Change password';
  }

  Future<void> _verify(String credential) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result =
          await widget.pinService.verifyPinDetailed(credential);
      if (!mounted) return;
      if (result.isSuccess) {
        setState(() {
          _busy = false;
          _verified = true;
          _currentCredential = credential;
        });
      } else {
        setState(() => _busy = false);
        _verifyKey.currentState?.showError(result.message);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _verifyKey.currentState?.showError(
          'Could not verify your ${_type.credentialNoun}. Please try again.');
    }
  }

  Future<void> _save(String credential) async {
    await widget.pinService.replaceCredential(
      type: _type,
      credential: credential,
    );
    if (!mounted) return;
    final label = _type.isPin ? 'PIN' : _type.credentialNoun;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label updated successfully.'),
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
        title: Text(_title),
        leading: const BackButton(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + keyboard),
          child: _verified
              ? CredentialSetupPanel(
                  type: _type,
                  currentCredential: _currentCredential,
                  firstHeading: _type.newCredentialHeading,
                  firstDescription: _type.newCredentialDescription,
                  confirmHeading: _type.newConfirmHeading,
                  confirmDescription: _type.newConfirmDescription,
                  onConfirmed: _save,
                )
              : CredentialEntryPanel(
                  key: _verifyKey,
                  type: _type,
                  heading: _type.changeHeading,
                  description: _type.changeDescription,
                  actionLabel: _busy ? 'Checking...' : 'Continue',
                  onCompleted: _verify,
                ),
        ),
      ),
    );
  }
}
