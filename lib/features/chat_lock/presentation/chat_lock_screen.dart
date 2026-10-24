import 'package:flutter/material.dart';

import '../../../core/state/app_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/buttons.dart';
import '../../../shared/widgets/cards.dart';
import '../models/chat_identity.dart';
import '../models/chat_lock_state.dart';

/// Management screen for the experimental Instagram Chat Lock.
///
/// The screen is reached through the Blue Lock self-authentication gate, so
/// viewing or removing the protected list already requires the configured
/// Blue Lock credential (PIN, pattern, password or biometrics).
class ChatLockScreen extends StatefulWidget {
  const ChatLockScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChatLockScreen> createState() => _ChatLockScreenState();
}

class _ChatLockScreenState extends State<ChatLockScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    await widget.controller.refreshChatLockState();
  }

  Future<void> _toggleEnabled(bool enabled) async {
    await widget.controller.setChatLockEnabled(enabled);
    if (!mounted) return;
    if (!enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat Lock is off. Existing app protection is unchanged.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openAccessibility() async {
    await widget.controller.openChatAccessibilitySettings();
    // The status is re-read when the user returns to Blue Lock.
  }

  Future<void> _addConversation({String? initial}) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _AddChatDialog(initial: initial),
    );
    if (raw == null || !mounted) return;
    final error = await widget.controller.addProtectedChat(raw);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ?? 'Conversation @${ChatIdentity.normalize(raw)} is protected.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _addDetected() async {
    final detected = widget.controller.chatLockState.lastDetectedChat;
    if (detected != null) await _addConversation(initial: detected);
  }

  Future<void> _removeConversation(String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Remove chat protection?',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: Text(
          '@$username will no longer require extra authentication. '
          'Blue Lock app-lock settings are not changed.',
          style: const TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep protected'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.removeProtectedChat(username);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('@$username is no longer protected.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _disableAndRevoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Disable and revoke?',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'Chat Lock will be turned off and all conversation sessions will '
          'expire. Android accessibility settings will open so you can revoke '
          'Blue Lock Chat Lock. Your app-lock protection and saved settings '
          'are not changed.',
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disable and open settings'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.clearChatLockSessions();
    await widget.controller.setChatLockEnabled(false);
    await _openAccessibility();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Instagram Chat Lock'),
        leading: const BackButton(color: AppColors.textPrimary),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'Re-check detection and permission state',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final state = controller.chatLockState;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _introCard(),
                const SizedBox(height: 18),
                const SectionTitle('Chat protection'),
                _protectionCard(controller, state),
                const SizedBox(height: 18),
                const SectionTitle('Accessibility access'),
                _accessibilityCard(controller, state),
                const SizedBox(height: 18),
                const SectionTitle('Detection test'),
                _detectionCard(controller, state),
                const SizedBox(height: 18),
                const SectionTitle('Protected conversations'),
                _protectedList(controller),
                const SizedBox(height: 18),
                const SectionTitle('Relock conversations'),
                _relockCard(controller),
                const SizedBox(height: 18),
                const SectionTitle('Privacy and limitations'),
                _limitationsCard(),
                const SizedBox(height: 18),
                SecondaryButton(
                  label: 'Disable Chat Lock and revoke access',
                  onPressed: _disableAndRevoke,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _introCard() {
    return BlueLockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.paleBlueSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.chat_bubble_outline_rounded,
                    size: 21, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Experimental conversation lock',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const StatusPill(label: 'Experimental', tone: StatusTone.warning),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Select Instagram conversations that should require your Blue '
            'Lock credential when opened. Detection uses Android accessibility '
            'information from Instagram\'s visible conversation header. It is '
            'best-effort, not a guarantee: Instagram can change its UI at any '
            'time and content can briefly appear before Blue Lock reacts.',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _protectionCard(AppController controller, ChatLockState state) {
    return BlueLockCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SwitchListTile(
        value: controller.chatLockEnabled,
        // Always allow turning the feature off, even if Instagram was
        // uninstalled while it was enabled.
        onChanged: state.instagramInstalled || controller.chatLockEnabled
            ? _toggleEnabled
            : null,
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Instagram chat protection',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        subtitle: Text(
          !state.instagramInstalled
              ? 'Instagram is not installed on this device'
              : !controller.chatLockEnabled
                  ? 'Protected conversations open normally'
                  : state.accessibilityEnabled
                      ? 'Protected conversations require your '
                          '${controller.authType.credentialNoun}'
                      : 'On, but inactive until accessibility is enabled',
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _accessibilityCard(AppController controller, ChatLockState state) {
    final connected = state.accessibilityEnabled && state.serviceConnected;
    return BlueLockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Blue Lock Chat Lock service',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              StatusPill(
                label: state.accessibilityEnabled ? 'Enabled' : 'Off',
                tone: state.accessibilityEnabled
                    ? StatusTone.success
                    : StatusTone.warning,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Android accessibility lets Blue Lock see the visible screen '
            'structure of Instagram. Blue Lock reads only a username-shaped '
            'header value. It does not read, store or upload message text, '
            'take screenshots, use OCR, use the network, tap message controls '
            'or send messages. The permission is optional and can be revoked '
            'at any time in Android Settings.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          _statusLine(
            'Permission',
            state.accessibilityEnabled ? 'Enabled in Android' : 'Not granted',
            state.accessibilityEnabled,
          ),
          const SizedBox(height: 6),
          _statusLine(
            'Service',
            connected
                ? 'Connected'
                : state.accessibilityEnabled
                    ? 'Waiting for Android to connect'
                    : 'Not running',
            connected,
          ),
          const SizedBox(height: 6),
          _statusLine(
            'Instagram',
            state.instagramInstalled
                ? 'Installed${state.instagramVersion == null ? '' : ' (${state.instagramVersion})'}'
                : 'Not installed',
            state.instagramInstalled,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton(
              onPressed: _openAccessibility,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                textStyle:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              child: Text(state.accessibilityEnabled
                  ? 'Manage accessibility access'
                  : 'Enable in accessibility settings'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusLine(String label, String value, bool ok) {
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.info_outline,
          size: 17,
          color: ok ? AppColors.success : AppColors.warning,
        ),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _detectionCard(AppController controller, ChatLockState state) {
    // Only show an identifier while the *current* scan is a successful
    // detection. Otherwise a previous chat would remain on screen after the
    // user moved to the inbox or to an unidentifiable conversation.
    final detected = state.lastDetectionStatus == 'detected'
        ? state.lastDetectedChat
        : null;
    final protected = detected != null &&
        controller.protectedChats.contains(detected);
    return BlueLockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.detectionLabel,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Open Instagram, open a direct message, then return here. This '
            'panel shows only the identifier Blue Lock could read from the '
            'visible header - never message content.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
          if (detected != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '@$detected',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (protected)
                  const StatusPill(
                    label: 'Protected',
                    tone: StatusTone.success,
                  )
                else
                  TextButton(
                    onPressed: _addDetected,
                    child: const Text('Protect this chat'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _protectedList(AppController controller) {
    final chats = controller.protectedChats.toList()..sort();
    if (chats.isEmpty) {
      return BlueLockCard(
        child: Column(
          children: [
            const Icon(Icons.lock_open_rounded,
                size: 30, color: AppColors.textSecondary),
            const SizedBox(height: 10),
            const Text(
              'No conversations protected yet',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Add a 1:1 Instagram conversation by username. Group chats and '
              'display names are not supported because they do not provide a '
              'reliable identifier.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            PrimaryButton(
              label: 'Add conversation',
              icon: Icons.add_rounded,
              onPressed: _addConversation,
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        BlueLockCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Column(
            children: [
              for (var i = 0; i < chats.length; i++) ...[
                if (i > 0) const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.chat_bubble_outline_rounded,
                      color: AppColors.primary),
                  title: Text(
                    '@${chats[i]}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    'Requires your ${controller.authType.credentialNoun}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove protection',
                    onPressed: () => _removeConversation(chats[i]),
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: AppColors.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _addConversation,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Add another conversation'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _relockCard(AppController controller) {
    return BlueLockCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: _chatRelockOptions.map((option) {
          final selected =
              controller.chatRelockTimeoutSeconds == option.seconds;
          return InkWell(
            onTap: () => controller.setChatRelockTimeout(option.seconds),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color:
                        selected ? AppColors.primary : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      option.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _limitationsCard() {
    return BlueLockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _limitation(
            'Content can flash briefly before Android reports the conversation '
            'and Blue Lock covers the screen.',
          ),
          _limitation(
            'Notification previews, inbox snippets and Android Recents '
            'thumbnails are not hidden by this feature.',
          ),
          _limitation(
            'Only this device is protected. Instagram on another device, a '
            'browser or a linked account is unaffected.',
          ),
          _limitation(
            'Detection depends on Instagram\'s UI and accessibility tree. A '
            'layout change, a group chat or a display-name-only header can '
            'make a conversation unidentifiable; Blue Lock then does not guess.',
          ),
          _limitation(
            'A display name that happens to look like a username can cause an '
            'unnecessary prompt. That is an extra authentication step, never a '
            'weaker one.',
          ),
          _limitation(
            'This is not Instagram-native or operating-system-enforced '
            'encryption or access control, and it cannot bypass Instagram '
            'security. It is an additional local authentication gate.',
          ),
          _limitation(
            'Blue Lock has no Internet permission. No message text, header '
            'identifier or usage data is uploaded.',
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _limitation(String text, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.circle, size: 6, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatRelockOption {
  const _ChatRelockOption(this.label, this.seconds);
  final String label;
  final int seconds;
}

const _chatRelockOptions = <_ChatRelockOption>[
  _ChatRelockOption('Immediately after leaving a conversation', 0),
  _ChatRelockOption('After 30 seconds', 30),
  _ChatRelockOption('After 1 minute', 60),
  _ChatRelockOption('After 5 minutes', 300),
];

class _AddChatDialog extends StatefulWidget {
  const _AddChatDialog({this.initial});

  final String? initial;

  @override
  State<_AddChatDialog> createState() => _AddChatDialogState();
}

class _AddChatDialogState extends State<_AddChatDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized = ChatIdentity.normalize(_controller.text);
    if (normalized == null) {
      setState(() {
        _error = 'Enter a username: letters, numbers, dots or underscores, '
            'up to 30 characters.';
      });
      return;
    }
    Navigator.of(context).pop(normalized);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text(
        'Protect an Instagram conversation',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the username shown in the conversation header. Display '
            'names are not used because they are not unique. Group chats are '
            'not supported.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'username',
              prefixText: '@',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
