import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blue_lock/app.dart';
import 'package:blue_lock/core/services/native_bridge.dart';
import 'package:blue_lock/core/state/app_controller.dart';
import 'package:blue_lock/core/storage/app_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Build the controller outside the FakeAsync zone used by testWidgets so
  // platform-channel futures (plugins without handlers) can complete.
  late AppController controller;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = AppStorage();
    await storage.init();
    controller = AppController(
      storage: storage,
      native: NativeBridge(),
    );
    await controller.init();
  });

  testWidgets('splash shows Blue Lock branding and routes to onboarding',
      (tester) async {
    await tester.pumpWidget(BlueLockApp(controller: controller));

    expect(find.text('Blue Lock'), findsOneWidget);
    expect(find.text('Your apps. Your privacy.'), findsOneWidget);

    // Let the splash timer fire and the route transition complete.
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();

    expect(find.text('Keep your apps private'), findsOneWidget);
    expect(find.text('Get Started'), findsOneWidget);
  });
}
