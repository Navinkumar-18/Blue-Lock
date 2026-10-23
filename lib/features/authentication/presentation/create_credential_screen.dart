import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/credential_setup_panel.dart';

/// Configures and confirms a newly selected credential.
class CreateCredentialScreen extends StatelessWidget {
  const CreateCredentialScreen({
    super.key,
    required this.type,
    required this.onConfirmed,
  });

  final AuthenticationType type;
  final Future<void> Function(String credential) onConfirmed;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + keyboard),
          child: Column(
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: BackButton(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              const AppLogo(size: 64),
              const SizedBox(height: 24),
              CredentialSetupPanel(
                type: type,
                onConfirmed: onConfirmed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
