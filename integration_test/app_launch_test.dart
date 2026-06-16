// integration_test/app_launch_test.dart
//
// End-to-end UI smoke test for the WIOS Flutter client.
//
// Boots the real WoisApp under flutter_riverpod's ProviderScope on a
// connected device or emulator, lets the router settle on the login
// screen, and verifies the user-visible "Sign in with Google" affordance
// exists. Catches regressions where:
//   - main.dart wiring breaks (ProviderScope, GoRouter, MaterialApp)
//   - LoginScreen fails to render
//   - Required dependencies fail to initialise
//
// Does NOT exercise network: gateway calls are not made — we only verify
// the app reaches a stable first paint.
//
// Run from WarehouseSimulator/:
//     puro flutter test integration_test/app_launch_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:warehouse_simulator/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('WIOS Flutter client — first paint', () {
    testWidgets('boots and lands on a stable screen (no exceptions thrown)',
        (WidgetTester tester) async {
      // Launch the real app. main() will runApp(WoisApp()) inside ProviderScope.
      app.main();

      // Give the GoRouter + Riverpod providers + theme + fonts time to settle.
      // pumpAndSettle would hang if the LoginScreen has an indefinite animation
      // (the WIOS UI does have a subtle pulse on the logo), so we tick manually.
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // The most reliable invariant: there is exactly one MaterialApp in the
      // tree, and it has a Navigator. If GoRouter or main.dart broke wiring,
      // these wouldn't both hold.
      expect(find.byType(MaterialApp), findsOneWidget,
          reason: 'main.dart should construct exactly one MaterialApp');
      expect(find.byType(Navigator), findsWidgets,
          reason: 'GoRouter should have produced at least one Navigator');

      // No Flutter framework exception was raised during boot.
      final framework = TestWidgetsFlutterBinding.instance;
      expect(framework.takeException(), isNull,
          reason: 'app boot should not throw');
    });

    testWidgets('renders a sign-in affordance on the login screen',
        (WidgetTester tester) async {
      app.main();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // The LoginScreen presents OAuth sign-in entry points. We don't tap
      // them (that would launch a browser via url_launcher and fail in CI).
      // We just verify the text is visible — proves the LoginScreen widget
      // tree rendered, not just that the app booted.
      final hasSignInText =
          find.textContaining(RegExp(r'Sign in|Login|Google|LinkedIn',
                  caseSensitive: false))
              .evaluate()
              .isNotEmpty;
      expect(hasSignInText, isTrue,
          reason: 'login screen should advertise at least one auth provider');
    });
  });
}
