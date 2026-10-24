import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/features/chat_lock/models/chat_identity.dart';
import 'package:blue_lock/features/chat_lock/models/chat_lock_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatIdentity', () {
    test('normalises a username and strips a leading @', () {
      expect(ChatIdentity.normalize('  @Jane.Doe  '), 'jane.doe');
      expect(ChatIdentity.normalize('jane_doe'), 'jane_doe');
      expect(ChatIdentity.normalize('USER123'), 'user123');
    });

    test('rejects display names, invalid characters and empty values', () {
      expect(ChatIdentity.normalize('Jane Doe'), isNull);
      expect(ChatIdentity.normalize('jane-doe'), isNull);
      expect(ChatIdentity.normalize('jane doe'), isNull);
      expect(ChatIdentity.normalize(''), isNull);
      expect(ChatIdentity.normalize('   '), isNull);
      expect(ChatIdentity.normalize(null), isNull);
      expect(ChatIdentity.normalize('a' * 31), isNull);
      expect(ChatIdentity.normalize('..__'), isNull);
    });

    test('rejects username-shaped UI chrome and common words', () {
      expect(ChatIdentity.normalize('messages'), isNull);
      expect(ChatIdentity.normalize('Back'), isNull);
      expect(ChatIdentity.normalize('instagram.com'), isNull);
      expect(ChatIdentity.normalize('online'), isNull);
    });

    test('a one-character handle is a valid username', () {
      expect(ChatIdentity.normalize('a'), 'a');
    });
  });

  group('ChatLockState', () {
    test('parses the native payload', () {
      final state = ChatLockState.fromMap(<String, Object?>{
        'enabled': true,
        'relockTimeout': 30,
        'protectedChats': <Object?>['jane_doe', '', 7],
        'accessibilityEnabled': true,
        'serviceConnected': false,
        'instagramInstalled': true,
        'instagramVersion': '300.0.0',
        'lastDetectedChat': 'jane_doe',
        'lastDetectionStatus': 'detected',
        'lastDetectionAt': 1234,
      });
      expect(state.enabled, isTrue);
      expect(state.relockTimeout, 30);
      expect(state.protectedChats, {'jane_doe'});
      expect(state.accessibilityEnabled, isTrue);
      expect(state.serviceConnected, isFalse);
      expect(state.instagramInstalled, isTrue);
      expect(state.instagramVersion, '300.0.0');
      expect(state.lastDetectedChat, 'jane_doe');
      expect(state.lastDetectionStatus, 'detected');
      expect(state.lastDetectionAt, 1234);
    });

    test('falls back to unknown for a missing or malformed payload', () {
      expect(ChatLockState.fromMap(null).enabled, isFalse);
      expect(ChatLockState.fromMap('nope').lastDetectionStatus, 'not_scanned');
      expect(
        ChatLockState.fromMap(<String, Object?>{'protectedChats': 'x'})
            .protectedChats,
        isEmpty,
      );
    });
  });

  group('chat lock storage', () {
    test('defaults are off with no protected conversations', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = AppStorage();
      await storage.init();
      expect(storage.chatLockEnabled, isFalse);
      expect(storage.protectedChats, isEmpty);
      expect(storage.chatRelockTimeoutSeconds, 0);
    });

    test('settings roundtrip through local storage', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = AppStorage();
      await storage.init();
      await storage.setChatLockEnabled(true);
      await storage.setProtectedChats(['jane_doe', 'john.doe']);
      await storage.setChatRelockTimeoutSeconds(60);
      expect(storage.chatLockEnabled, isTrue);
      expect(storage.protectedChats, ['jane_doe', 'john.doe']);
      expect(storage.chatRelockTimeoutSeconds, 60);
    });
  });

  group('AppController chat lock', () {
    test('normalises, de-duplicates and removes protected conversations',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = AppStorage();
      await storage.init();
      final controller = AppController(
        storage: storage,
        native: NativeBridge(),
      );
      await controller.init();

      expect(await controller.addProtectedChat('@Jane_Doe'), isNull);
      expect(controller.protectedChats, {'jane_doe'});
      expect(await controller.addProtectedChat('jane_doe'), contains('already'));
      expect(await controller.addProtectedChat('Jane Doe'), isNotNull);
      expect(controller.protectedChats, {'jane_doe'});

      await controller.removeProtectedChat('JANE_DOE');
      expect(controller.protectedChats, isEmpty);
      expect(storage.protectedChats, isEmpty);
    });
  });
}
