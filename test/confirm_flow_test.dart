import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/app.dart';
import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/core/utils/perf_log.dart';
import 'package:blue_lock/core/utils/pin_crypto.dart';
import 'package:blue_lock/features/app_lock/presentation/self_lock_screen.dart';
import 'package:blue_lock/features/dashboard/presentation/home_shell.dart';

/// End-to-end coverage of the first-time setup flow (splash -> onboarding ->
/// create PIN -> confirm PIN -> home), plus duplicate-submission, mismatch,
/// storage-failure and returning-user behaviour.
///
/// Prints elapsed time from the fourth confirmation digit to the Home Shell
/// becoming present. Only durations are logged - never PINs, hashes or salts.
/// Test-only PBKDF2 derivation: the synchronous variant so the flow test
/// stays deterministic off the isolate path (which has its own coverage in
/// pin_crypto_async_test).
Future<Uint8List> _testDerive(String pin, Uint8List salt) async =>
    PinCrypto.deriveVerifier(pin, salt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory stand-in for the platform secure-storage channel so the PIN
  // verifier persists across AppStorage instances like it would on device.
  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  var secureWriteCount = 0;
  var failWrites = false;
  var silentWrites = false;

  setUp(() {
    secureStore.clear();
    secureWriteCount = 0;
    failWrites = false;
    silentWrites = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map).cast<String, dynamic>();
      switch (call.method) {
        case 'read':
          return secureStore[args['key']];
        case 'write':
          if (failWrites) {
            throw PlatformException(code: 'write_error');
          }
          if (!silentWrites) {
            secureStore[args['key']] = args['value'] as String;
          }
          secureWriteCount++;
          return null;
        case 'delete':
          secureStore.remove(args['key']);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(args['key']);
      }
      return null;
    });
  });

  Future<AppController> makeController() async {
    final storage = AppStorage();
    await storage.init();
    final controller = AppController(
      storage: storage,
      native: NativeBridge(),
      // Hermetic in test builds: the PBKDF2 derivation runs synchronously on
      // the test isolate. The production dispatch (background isolate / web
      // WebCrypto) is covered by pin_crypto_async_test.
      services: const AppControllerServices(
        derive: _testDerive,
      ),
    );
    await controller.init();
    return controller;
  }

  Future<void> boot(WidgetTester tester, AppController controller) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BlueLockApp(controller: controller));
    // Splash timer (1300ms) runs on the fake clock.
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
  }

  Future<void> enterDigits(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
  }

  /// Lets real asynchronous work (background derive, channel mocks) progress
  /// while fake-clock frames keep rendering, until [isDone] or ~2.5s.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() isDone, {
    int maxIterations = 250,
  }) async {
    for (var i = 0; i < maxIterations && !isDone(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('first-time setup reaches home; verifier persisted once',
      (tester) async {
    final controller = await makeController();
    await boot(tester, controller);

    expect(find.text('Keep your apps private'), findsOneWidget);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(find.text('Create your PIN'), findsOneWidget);

    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();
    expect(find.text('Confirm your PIN'), findsOneWidget);

    // First three confirmation digits.
    await enterDigits(tester, '123');

    // Fourth confirmation digit: start measuring until Home is present.
    final sw = Stopwatch()..start();
    await tester.tap(find.text('4'));
    await tester.pump(); // rebuild: action button is now enabled
    // Duplicate submission attempt while the first one is processing.
    await tester.tap(find.byType(FilledButton));

    await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    sw.stop();
    // ignore: avoid_print
    print('[perf] fourth confirm digit -> HomeShell present: '
        '${sw.elapsedMilliseconds}ms '
        '(marks since boot: digit4 +${PerfLog.markMs}ms, '
        'home frame +${PerfLog.homeFrameMs}ms)');

    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.text('Your privacy'), findsOneWidget);

    // Salt + verifier written exactly once (two channel writes).
    expect(secureWriteCount, 2,
        reason: 'salt and verifier must be persisted exactly once');
    expect(secureStore.containsKey('pin_verifier'), isTrue);
    expect(secureStore.containsKey('pin_salt'), isTrue);
    expect(controller.onboardingDone, isTrue);
    expect(controller.hasPin, isTrue);
    // Stored values must be salt+verifier, never the PIN itself.
    expect(secureStore.values.contains('1234'), isFalse);
  });

  testWidgets('mismatched confirmation PIN is rejected without saving',
      (tester) async {
    final controller = await makeController();
    await boot(tester, controller);

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();

    await enterDigits(tester, '9876');
    await tester.pumpAndSettle();

    expect(find.text("PINs don't match. Try again."), findsWidgets);
    expect(find.text('Confirm your PIN'), findsOneWidget);
    expect(secureWriteCount, 0);
    expect(controller.onboardingDone, isFalse);
    expect(controller.hasPin, isFalse);
  });

  testWidgets('storage write failure surfaces an error and setup stays '
      'incomplete', (tester) async {
    failWrites = true;
    final controller = await makeController();
    await boot(tester, controller);

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');

    await waitFor(tester,
        () => find.text('Could not save your PIN. Please try again.').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    expect(find.byType(HomeShell), findsNothing);
    expect(find.text('Confirm your PIN'), findsOneWidget);
    expect(
      find.text('Could not save your PIN. Please try again.'),
      findsWidgets,
    );
    expect(controller.onboardingDone, isFalse,
        reason: 'failed storage must not mark setup complete');
    expect(controller.hasPin, isFalse);
  });

  testWidgets('silently-dropped storage write is caught by read-back',
      (tester) async {
    silentWrites = true;
    final controller = await makeController();
    await boot(tester, controller);

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');

    await waitFor(tester,
        () => find.text('Could not save your PIN. Please try again.').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    expect(find.byType(HomeShell), findsNothing);
    expect(
      find.text('Could not save your PIN. Please try again.'),
      findsWidgets,
    );
    expect(controller.onboardingDone, isFalse);
    expect(controller.hasPin, isFalse);
  });

  testWidgets('returning user with stored PIN skips setup but must '
      'authenticate to reach home (self-lock)', (tester) async {
    // Complete setup once so state is fully persisted.
    final first = await makeController();
    await boot(tester, first);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();
    await enterDigits(tester, '1234');
    await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);

    // Cold start with the same persisted storage.
    await tester.pumpWidget(const SizedBox.shrink());
    final returning = await makeController();
    await boot(tester, returning);

    expect(find.text('Create your PIN'), findsNothing,
        reason: 'setup must be skipped for a returning user');
    expect(find.byType(SelfLockScreen), findsOneWidget,
        reason: 'reopening Blue Lock must require authentication');
    expect(find.byType(HomeShell), findsNothing,
        reason: 'dashboard must stay unreachable until authenticated');

    // The stored PIN unlocks Blue Lock.
    await enterDigits(tester, '1234');
    await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(SelfLockScreen), findsNothing);
  });

  testWidgets('enter-PIN screen rejects a wrong PIN and accepts the right one',
      (tester) async {
    // Persist a known PIN, then rewind onboarding so the returner path
    // through onboarding stays reachable. Flag must be false before the
    // controller reads it during init.
    final setup = await makeController();
    await setup.pinService.createPin('1234');
    await setup.storage.setOnboardingDone(false);

    await tester.pumpWidget(const SizedBox.shrink());
    final controller = await makeController();
    await boot(tester, controller);
    expect(find.text('Keep your apps private'), findsOneWidget);
    expect(find.text('I already have a PIN'), findsOneWidget);

    await tester.tap(find.text('I already have a PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);

    await enterDigits(tester, '0000');
    await waitFor(tester,
        () => find.text('Incorrect PIN. Try again.').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Incorrect PIN. Try again.'), findsWidgets);
    expect(find.text('Enter your PIN'), findsOneWidget);

    await enterDigits(tester, '1234');
    await waitFor(tester, () => find.byType(HomeShell).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
  });
}
