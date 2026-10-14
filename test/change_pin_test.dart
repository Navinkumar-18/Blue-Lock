import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/core/storage/app_storage.dart';
import 'package:blue_lock/core/utils/pin_crypto.dart';
import 'package:blue_lock/features/authentication/presentation/change_pin_screen.dart';
import 'package:blue_lock/features/authentication/services/pin_service.dart';

Future<Uint8List> _testDerive(String pin, Uint8List salt) async =>
    PinCrypto.deriveVerifier(pin, salt);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  var failWrites = false;

  setUp(() {
    secureStore.clear();
    failWrites = false;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = call.arguments as Map<dynamic, dynamic>? ?? {};
      switch (call.method) {
        case 'read':
          return secureStore[args['key']];
        case 'write':
          if (failWrites) {
            throw PlatformException(code: 'write_error', message: 'Disk write failed');
          }
          secureStore[args['key']] = args['value'] as String;
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

  Future<PinService> createPinServiceWithInitialPin(String pin) async {
    final storage = AppStorage();
    await storage.init();
    final service = PinService(storage, derive: _testDerive);
    await service.createPin(pin);
    return service;
  }

  Future<void> enterDigits(WidgetTester tester, String digits) async {
    for (final d in digits.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
  }

  testWidgets('incorrect current PIN is rejected and stays on verify step',
      (tester) async {
    final service = await createPinServiceWithInitialPin('1234');
    await tester.pumpWidget(
      MaterialApp(
        home: ChangePinScreen(pinService: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter current PIN'), findsOneWidget);

    // Enter wrong PIN 9999
    await enterDigits(tester, '9999');
    await tester.pumpAndSettle();

    expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
    expect(find.text('Enter current PIN'), findsOneWidget);
  });

  testWidgets('correct current PIN advances cleanly to create new PIN',
      (tester) async {
    final service = await createPinServiceWithInitialPin('1234');
    await tester.pumpWidget(
      MaterialApp(
        home: ChangePinScreen(pinService: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter current PIN'), findsOneWidget);

    // Enter correct PIN 1234
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();

    expect(find.text('Create new PIN'), findsOneWidget);
    expect(find.text('Choose a new 4-digit PIN for your apps.'), findsOneWidget);
  });

  testWidgets('new PIN identical to current PIN is rejected',
      (tester) async {
    final service = await createPinServiceWithInitialPin('1234');
    await tester.pumpWidget(
      MaterialApp(
        home: ChangePinScreen(pinService: service),
      ),
    );
    await tester.pumpAndSettle();

    // Verify current PIN
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();
    expect(find.text('Create new PIN'), findsOneWidget);

    // Try same PIN 1234 as new PIN
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();

    expect(find.text('New PIN must be different from the current PIN.'),
        findsOneWidget);
    expect(find.text('Create new PIN'), findsOneWidget);
  });

  testWidgets('mismatched confirm PIN is rejected and allows re-entry',
      (tester) async {
    final service = await createPinServiceWithInitialPin('1234');
    await tester.pumpWidget(
      MaterialApp(
        home: ChangePinScreen(pinService: service),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Verify current PIN
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();

    // 2. Enter new PIN 5678
    await enterDigits(tester, '5678');
    await tester.pumpAndSettle();
    expect(find.text('Confirm new PIN'), findsOneWidget);

    // 3. Enter mismatched confirmation 5679
    await enterDigits(tester, '5679');
    await tester.pumpAndSettle();

    expect(find.text("PINs don't match. Try again."), findsOneWidget);
    expect(find.text('Confirm new PIN'), findsOneWidget);
  });

  testWidgets(
      'successful PIN change updates verifier: old PIN fails, new PIN succeeds',
      (tester) async {
    final service = await createPinServiceWithInitialPin('1234');
    bool? popResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popResult = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => ChangePinScreen(pinService: service),
                ),
              );
            },
            child: const Text('Open Change PIN'),
          ),
        ),
      ),
    );

    // Open screen
    await tester.tap(find.text('Open Change PIN'));
    await tester.pumpAndSettle();

    // 1. Enter current PIN 1234
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();
    expect(find.text('Create new PIN'), findsOneWidget);

    // 2. Enter new PIN 5678
    await enterDigits(tester, '5678');
    await tester.pumpAndSettle();
    expect(find.text('Confirm new PIN'), findsOneWidget);

    // 3. Confirm new PIN 5678
    await enterDigits(tester, '5678');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify screen popped with true
    expect(popResult, isTrue);
    expect(find.text('PIN updated successfully.'), findsOneWidget);
    await tester.pumpAndSettle();

    // 4. Verify in storage/service: old PIN rejected, new PIN accepted
    expect(await service.verifyPin('1234'), isFalse);
    expect(await service.verifyPin('5678'), isTrue);
  });

  testWidgets('storage failure during changePin surfaces error and restores busy',
      (tester) async {
    final service = await createPinServiceWithInitialPin('1234');

    await tester.pumpWidget(
      MaterialApp(
        home: ChangePinScreen(pinService: service),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Current PIN
    await enterDigits(tester, '1234');
    await tester.pumpAndSettle();

    // 2. New PIN
    await enterDigits(tester, '5678');
    await tester.pumpAndSettle();

    // Cause storage write failure
    failWrites = true;

    // 3. Confirm PIN
    await enterDigits(tester, '5678');
    await tester.pumpAndSettle();

    // Error displayed, did not pop
    expect(find.text('Could not save your PIN. Please try again.'), findsOneWidget);
    expect(find.text('Confirm new PIN'), findsOneWidget);

    // Original PIN still intact
    failWrites = false;
    expect(await service.verifyPin('1234'), isTrue);
  });
}
