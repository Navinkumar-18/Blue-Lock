import 'package:flutter/material.dart';

import '../../../core/authentication/authentication_type.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/branding.dart';
import '../../../shared/widgets/cards.dart';

/// Full-screen "Choose Your Lock Type" step used during first-run setup.
class ChooseLockTypeScreen extends StatelessWidget {
  const ChooseLockTypeScreen({
    super.key,
    this.currentType,
    this.onSelected,
  });

  /// When set, the matching option is marked as the current method.
  final AuthenticationType? currentType;

  /// Defaults to pushing the shared credential setup route.
  final ValueChanged<AuthenticationType>? onSelected;

  void _select(BuildContext context, AuthenticationType type) {
    if (onSelected != null) {
      onSelected!(type);
      return;
    }
    Navigator.of(context).pushNamed('/create-credential', arguments: type);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: BackButton(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              const Center(child: AppLogo(size: 64)),
              const SizedBox(height: 24),
              const Text(
                'Choose your lock type',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Pick the credential you will use to unlock protected apps '
                'and Blue Lock itself. You can change it later in Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              LockTypeOptionList(
                currentType: currentType,
                onSelected: (type) => _select(context, type),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reusable option list shared by setup and Change Lock Type.
class LockTypeOptionList extends StatelessWidget {
  const LockTypeOptionList({
    super.key,
    required this.onSelected,
    this.currentType,
  });

  final ValueChanged<AuthenticationType> onSelected;
  final AuthenticationType? currentType;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final type in AuthenticationType.values) ...[
          _LockTypeCard(
            type: type,
            current: currentType == type,
            onTap: () => onSelected(type),
          ),
          if (type != AuthenticationType.values.last)
            const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _LockTypeCard extends StatelessWidget {
  const _LockTypeCard({
    required this.type,
    required this.current,
    required this.onTap,
  });

  final AuthenticationType type;
  final bool current;
  final VoidCallback onTap;

  IconData get _icon {
    switch (type) {
      case AuthenticationType.pin4Digit:
        return Icons.pin_outlined;
      case AuthenticationType.pin6Digit:
        return Icons.pin_rounded;
      case AuthenticationType.pattern:
        return Icons.gesture_rounded;
      case AuthenticationType.password:
        return Icons.password_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${type.title}. ${type.description}'
          '${current ? ' Currently selected.' : ''}',
      child: BlueLockCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.paleBlueSoft,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(_icon, color: AppColors.primary, size: 23),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          type.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (current) ...[
                        const SizedBox(width: 8),
                        const StatusPill(
                          label: 'Current',
                          tone: StatusTone.neutral,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    type.description,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
