import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/credential_entry_panel.dart';
import '../services/pin_service.dart';

/// Returning-user verification from onboarding ("I already have a lock").
///
/// Renders whichever credential type is currently stored, so the onboarding
/// return path can never force a PIN on a pattern/password user.
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
  final GlobalKey<CredentialEntryPanelState> _panelKey =
      GlobalKey<CredentialEntryPanelState>();
  AuthenticationType _type = AuthenticationType.pin4Digit;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _type = widget.pinService.authType;
    _syncType();
  }

  Future<void> _syncType() async {
    final type = await widget.pinService.loadAuthType();
    if (!mounted) return;
    if (type != _type) setState(() => _type = type);
  }

  String get _heading {
    if (_type.isPin) return 'Enter your PIN';
    if (_type.isPattern) return 'Draw your pattern';
    return 'Enter your password';
  }

  String get _description {
    if (_type.isPin) {
      return 'Verify your ${_type.shortLabel} to continue to Blue Lock.';
    }
    return 'Verify your ${_type.credentialNoun} to continue to Blue Lock.';
  }

  Future<void> _onCompleted(String credential) async {
    if (_checking) return;
    setState(() => _checking = true);
    PinVerification result;
    try {
      result = await widget.pinService.verifyPinDetailed(credential);
    } catch (_) {
      // Storage/crypto failure - do not report it as an incorrect credential.
      if (!mounted) return;
      setState(() => _checking = false);
      _panelKey.currentState?.showError(
          'Could not verify your ${_type.credentialNoun}. Try again.');
      return;
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (result.isSuccess) {
      widget.onVerified();
    } else {
      _panelKey.currentState?.showError(result.message);
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
              CredentialEntryPanel(
                key: _panelKey,
                type: _type,
                heading: _heading,
                description: _description,
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
