/// Instagram conversation identifier rules shared with the native detector.
///
/// Only a normalised username is ever used as a conversation key. Display
/// names are not unique and are deliberately never treated as identifiers.
class ChatIdentity {
  ChatIdentity._();

  static final RegExp _username = RegExp(r'^[A-Za-z0-9._]{1,30}$');

  /// Username-shaped UI chrome and common words. Kept in sync with
  /// `ChatIdentity.kt` so Dart and the native detector always agree on what
  /// counts as a usable conversation key.
  static const Set<String> _rejected = <String>{
    'instagram', 'direct', 'inbox', 'message', 'messages', 'search',
    'back', 'close', 'send', 'sent', 'seen', 'delivered', 'now',
    'active', 'online', 'typing', 'reply', 'share', 'like', 'liked',
    'comment', 'comments', 'follow', 'following', 'followers',
    'profile', 'photo', 'photos', 'video', 'videos', 'audio', 'call',
    'calls', 'voice', 'record', 'camera', 'gallery', 'sticker', 'stickers',
    'gif', 'gifs', 'emoji', 'more', 'options', 'details', 'next', 'done',
    'cancel', 'delete', 'edit', 'add', 'new', 'home', 'reels', 'explore',
    'notes', 'note', 'story', 'stories', 'settings', 'requests', 'request',
    'suggested', 'muted', 'pinned', 'restricted', 'blocked', 'report',
    'unread', 'read', 'today', 'yesterday', 'ago', 'type', 'hold',
    'http', 'https', 'www', 'com', 'instagram.com',
  };

  /// Returns a lowercase handle without the leading `@`, or null when the
  /// value is not a plausible Instagram username.
  static String? normalize(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.startsWith('@')) value = value.substring(1).trim();
    if (value.isEmpty || value.length > 30) return null;
    if (!_username.hasMatch(value)) return null;
    value = value.toLowerCase();
    if (_rejected.contains(value)) return null;
    if (value.split('').every((c) => c == '.' || c == '_')) return null;
    return value;
  }

  static bool isValid(String? raw) => normalize(raw) != null;

  /// Display form used in Blue Lock's own management UI.
  static String display(String username) => '@$username';
}
