import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart model of the native LockPrefs session logic to verify invariants:
/// 1. Timeout == 0 stores foreground-only session (`fg_only_<pkg>`).
/// 2. Timeout > 0 stores expiry timestamp (`expiry_<pkg>`).
/// 3. Leaving an app with timeout == 0 invalidates session immediately.
/// 4. Leaving an app with timeout > 0 does NOT invalidate session before expiry.
/// 5. Reboot / screen-off clears foreground-only sessions.
class SessionStore {
  final Map<String, dynamic> _store = {};

  int relockTimeout = 0; // Default: immediate

  void unlock(String packageName, int timeoutSeconds) {
    if (timeoutSeconds <= 0) {
      _store['fg_only_$packageName'] = true;
      _store.remove('expiry_$packageName');
    } else {
      final expiry = DateTime.now().millisecondsSinceEpoch + timeoutSeconds * 1000;
      _store['expiry_$packageName'] = expiry;
      _store.remove('fg_only_$packageName');
    }
  }

  bool isUnlocked(String packageName) {
    if (_store.containsKey('fg_only_$packageName')) return true;
    final expiry = _store['expiry_$packageName'] as int?;
    if (expiry != null) {
      return expiry > DateTime.now().millisecondsSinceEpoch;
    }
    return false;
  }

  void clearSession(String packageName) {
    _store.remove('fg_only_$packageName');
    _store.remove('expiry_$packageName');
  }

  void clearForegroundOnlySessions() {
    _store.removeWhere((k, _) => k.startsWith('fg_only_'));
  }

  /// Service transition logic
  void onAppTransition({
    required String? previous,
    required String? fg,
    required Set<String> protectedApps,
    required String ownPackage,
    required bool isLockActivityForPrevious,
  }) {
    if (previous != null && previous != fg) {
      if (protectedApps.contains(previous)) {
        if (!isLockActivityForPrevious && relockTimeout <= 0) {
          clearSession(previous);
        }
      }
    }
  }
}

void main() {
  group('Relock Policy & Session Invariants', () {
    test('default timeout is 0 (immediate)', () {
      final store = SessionStore();
      expect(store.relockTimeout, 0);
    });

    test('immediate unlock creates fg_only key and validates unlocked', () {
      final store = SessionStore();
      store.unlock('com.example.app', 0);
      expect(store.isUnlocked('com.example.app'), isTrue);
    });

    test('transitioning away from immediate app invalidates session', () {
      final store = SessionStore();
      final protectedApps = {'com.example.app'};
      store.unlock('com.example.app', 0);
      expect(store.isUnlocked('com.example.app'), isTrue);

      // User presses Home (transition to launcher)
      store.onAppTransition(
        previous: 'com.example.app',
        fg: 'com.android.launcher',
        protectedApps: protectedApps,
        ownPackage: 'com.bluelock.app',
        isLockActivityForPrevious: false,
      );

      // App is now relocked immediately
      expect(store.isUnlocked('com.example.app'), isFalse);
    });

    test('lock-loop prevention: transition to LockActivity for target does NOT clear session', () {
      final store = SessionStore();
      final protectedApps = {'com.example.app'};
      store.unlock('com.example.app', 0);

      // While LockActivity is showing for target app, transition to own package occurs
      store.onAppTransition(
        previous: 'com.example.app',
        fg: 'com.bluelock.app',
        protectedApps: protectedApps,
        ownPackage: 'com.bluelock.app',
        isLockActivityForPrevious: true,
      );

      // Session must be preserved to prevent lock loop
      expect(store.isUnlocked('com.example.app'), isTrue);
    });

    test('timed session (30s) survives app transition before expiry', () {
      final store = SessionStore();
      store.relockTimeout = 30;
      final protectedApps = {'com.example.app'};
      store.unlock('com.example.app', 30);
      expect(store.isUnlocked('com.example.app'), isTrue);

      // User switches to another app
      store.onAppTransition(
        previous: 'com.example.app',
        fg: 'com.android.launcher',
        protectedApps: protectedApps,
        ownPackage: 'com.bluelock.app',
        isLockActivityForPrevious: false,
      );

      // Within 30 seconds, app is still unlocked
      expect(store.isUnlocked('com.example.app'), isTrue);
    });

    test('screen-off / reboot clears foreground-only sessions but keeps timed sessions', () {
      final store = SessionStore();
      store.unlock('com.app.immediate', 0);
      store.unlock('com.app.timed', 300);

      expect(store.isUnlocked('com.app.immediate'), isTrue);
      expect(store.isUnlocked('com.app.timed'), isTrue);

      store.clearForegroundOnlySessions();

      expect(store.isUnlocked('com.app.immediate'), isFalse);
      expect(store.isUnlocked('com.app.timed'), isTrue);
    });
  });
}
