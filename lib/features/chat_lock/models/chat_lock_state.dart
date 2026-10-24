/// Native state of the experimental Instagram Chat Lock.
///
/// [lastDetectedChat] is a normalised username only; no message bodies or
/// notification content cross the platform channel. [lastDetectionStatus] is
/// a diagnostic code suitable for explaining why a conversation was or was
/// not recognised.
class ChatLockState {
  const ChatLockState({
    this.enabled = false,
    this.relockTimeout = 0,
    this.protectedChats = const <String>{},
    this.accessibilityEnabled = false,
    this.serviceConnected = false,
    this.instagramInstalled = false,
    this.instagramVersion,
    this.lastDetectedChat,
    this.lastDetectionStatus = 'not_scanned',
    this.lastDetectionAt = 0,
  });

  final bool enabled;
  final int relockTimeout;
  final Set<String> protectedChats;

  /// Whether Blue Lock's accessibility service is enabled in Android settings.
  final bool accessibilityEnabled;

  /// Whether the enabled service is currently connected (bound by Android).
  final bool serviceConnected;

  final bool instagramInstalled;
  final String? instagramVersion;
  final String? lastDetectedChat;
  final String lastDetectionStatus;
  final int lastDetectionAt;

  static const ChatLockState unknown = ChatLockState();

  factory ChatLockState.fromMap(dynamic raw) {
    if (raw is! Map) return unknown;
    final map = Map<dynamic, dynamic>.from(raw);
    final chats = <String>{};
    final rawChats = map['protectedChats'];
    if (rawChats is List) {
      for (final value in rawChats) {
        if (value is String && value.isNotEmpty) chats.add(value);
      }
    }
    return ChatLockState(
      enabled: map['enabled'] == true,
      relockTimeout: (map['relockTimeout'] as num?)?.toInt() ?? 0,
      protectedChats: chats,
      accessibilityEnabled: map['accessibilityEnabled'] == true,
      serviceConnected: map['serviceConnected'] == true,
      instagramInstalled: map['instagramInstalled'] == true,
      instagramVersion: map['instagramVersion'] as String?,
      lastDetectedChat: map['lastDetectedChat'] as String?,
      lastDetectionStatus:
          map['lastDetectionStatus'] as String? ?? 'not_scanned',
      lastDetectionAt: (map['lastDetectionAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// Human-readable, privacy-safe explanation of the last detection result.
  String get detectionLabel {
    switch (lastDetectionStatus) {
      case 'service_connected':
        return 'Accessibility service connected. Open a DM to test detection.';
      case 'service_disconnected':
        return 'Accessibility service is not connected.';
      case 'detected':
        return lastDetectedChat == null
            ? 'Conversation detected.'
            : 'Conversation detected: @$lastDetectedChat';
      case 'conversation_no_username':
        return 'A conversation is open, but no username-like header was '
            'found. This conversation cannot be protected on this Instagram '
            'version.';
      case 'no_conversation':
        return 'Instagram is open, but no DM conversation was detected.';
      case 'no_window':
        return 'Instagram window information is not available right now.';
      case 'instagram_backgrounded':
        return 'Instagram is not in the foreground.';
      case 'monitoring_disabled':
        return 'Chat protection is off.';
      case 'no_protected_chats':
        return 'Chat protection is on, but no conversations are protected yet.';
      default:
        return 'No accessibility scan result yet.';
    }
  }

  ChatLockState copyWith({
    bool? enabled,
    int? relockTimeout,
    Set<String>? protectedChats,
    bool? accessibilityEnabled,
    bool? serviceConnected,
    bool? instagramInstalled,
    String? instagramVersion,
    String? lastDetectedChat,
    String? lastDetectionStatus,
    int? lastDetectionAt,
  }) {
    return ChatLockState(
      enabled: enabled ?? this.enabled,
      relockTimeout: relockTimeout ?? this.relockTimeout,
      protectedChats: protectedChats ?? this.protectedChats,
      accessibilityEnabled:
          accessibilityEnabled ?? this.accessibilityEnabled,
      serviceConnected: serviceConnected ?? this.serviceConnected,
      instagramInstalled: instagramInstalled ?? this.instagramInstalled,
      instagramVersion: instagramVersion ?? this.instagramVersion,
      lastDetectedChat: lastDetectedChat ?? this.lastDetectedChat,
      lastDetectionStatus:
          lastDetectionStatus ?? this.lastDetectionStatus,
      lastDetectionAt: lastDetectionAt ?? this.lastDetectionAt,
    );
  }
}
