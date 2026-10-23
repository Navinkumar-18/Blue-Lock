import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import 'self_lock_screen.dart';

/// App-entry authentication gate for Blue Lock itself.
///
/// Wraps every sensitive route: while Blue Lock's own unlock session is
/// missing or expired the child (dashboard, settings, PIN management, ...)
/// is never built or shown - the reused PIN/biometric lock screen is shown
/// instead. Success swaps the child in without any navigation, so the gate
/// cannot bounce the user back to the splash screen.
///
/// Only the top-most route renders the authentication screen; routes that
/// are covered keep a neutral placeholder so repeated lifecycle events or
/// stacked routes can never stack duplicate prompts.
class SelfAuthGate extends StatelessWidget {
  const SelfAuthGate({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppController controller;

  /// Sensitive content that must stay unreachable until authentication.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // First-run setup (no PIN yet): the gate stays out of the way so
        // onboarding and PIN creation can complete.
        if (!controller.selfSetupDone) return child;
        if (controller.selfUnlocked) return child;
        final route = ModalRoute.of(context);
        if (route != null && !route.isCurrent) {
          // Covered by another route: block the content, but never render a
          // second authentication screen (prevents overlapping prompts).
          return const ColoredBox(color: AppColors.background);
        }
        return PopScope(
          canPop: false,
          child: SelfLockScreen(controller: controller),
        );
      },
    );
  }
}
