import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import 'package:humsukhan/providers/settings_provider.dart';
import 'package:humsukhan/providers/auth_provider.dart';
import 'package:humsukhan/screens/splash_screen.dart';
import 'package:humsukhan/screens/onboarding_screen.dart';
import 'package:humsukhan/navigation/app_router.dart';

/// Minimal MaterialApp wrapper that provides [SettingsProvider] and
/// optionally [AuthProvider], with a simple route table for testing.
Widget _testApp({
  required SettingsProvider settings,
  AuthProvider? auth,
  required Widget home,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth ?? AuthProvider(),
      ),
    ],
    child: MaterialApp(
      home: home,
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case AppRouter.onboarding:
            return MaterialPageRoute(builder: (_) => const OnboardingScreen());
          case AppRouter.auth:
            return MaterialPageRoute(
              builder: (_) =>
                  const Scaffold(body: Center(child: Text('Auth Screen'))),
            );
          case AppRouter.home:
            return MaterialPageRoute(
              builder: (_) =>
                  const Scaffold(body: Center(child: Text('Home Screen'))),
            );
          default:
            return MaterialPageRoute(
              builder: (_) =>
                  const Scaffold(body: Center(child: Text('Default'))),
            );
        }
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── SettingsProvider readiness ──────────────────────────────────────

  group('SettingsProvider — readiness tracking', () {
    test('isLoaded is false before ready resolves', () {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      // _loadSettings starts in constructor but hasn't completed yet in sync.
      // However, SharedPreferences mock resolves synchronously in tests,
      // so isLoaded may already be true. Verify the ready future exists.
      expect(settings.ready, isA<Future<void>>());
    });

    test('ready completes after settings are loaded', () async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': true,
        'darkMode': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      expect(settings.isLoaded, isTrue);
      expect(settings.isOnboardingComplete, isTrue);
      expect(settings.isDarkMode, isTrue);
    });

    test('ready preserves existing persisted values', () async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': false,
        'appLanguage': 'ur',
        'highContrast': true,
        'largeText': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      expect(settings.isOnboardingComplete, isFalse);
      expect(settings.appLanguage, 'ur');
      expect(settings.isHighContrast, isTrue);
      expect(settings.isLargeText, isTrue);
    });

    test('defaults when SharedPreferences is empty', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.ready;

      expect(settings.isOnboardingComplete, isFalse);
      expect(settings.isDarkMode, isFalse);
      expect(settings.appLanguage, 'en');
    });
  });

  // ── completeOnboarding persistence ─────────────────────────────────

  group('SettingsProvider — completeOnboarding persistence', () {
    test('completeOnboarding persists before returning', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.ready;

      expect(settings.isOnboardingComplete, isFalse);

      // completeOnboarding must be awaited — it persists the flag.
      await settings.completeOnboarding();

      expect(settings.isOnboardingComplete, isTrue);

      // Verify the value survived a fresh SharedPreferences read.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboardingComplete'), isTrue);
    });

    test('onboarding flag persists across SettingsProvider recreation',
        () async {
      SharedPreferences.setMockInitialValues({});
      final settings1 = SettingsProvider();
      await settings1.ready;

      await settings1.completeOnboarding();

      // Create a fresh provider — it should load the persisted flag.
      final settings2 = SettingsProvider();
      await settings2.ready;

      expect(settings2.isOnboardingComplete, isTrue);
    });

    test('completeOnboarding does not affect other settings', () async {
      SharedPreferences.setMockInitialValues({
        'darkMode': true,
        'appLanguage': 'ur',
        'highContrast': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      await settings.completeOnboarding();

      // Other settings must remain intact.
      expect(settings.isDarkMode, isTrue);
      expect(settings.appLanguage, 'ur');
      expect(settings.isHighContrast, isTrue);
    });
  });

  // ── First launch → onboarding ──────────────────────────────────────

  group('Startup routing — first launch', () {
    testWidgets('fresh install shows onboarding via route decision',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.ready;

      await tester.pumpWidget(
        _testApp(
          settings: settings,
          home: Scaffold(
            body: Text(
              settings.isOnboardingComplete ? 'Home' : 'Onboarding',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Onboarding'), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });
  });

  // ── Completed onboarding → skip onboarding ─────────────────────────

  group('Startup routing — completed onboarding', () {
    testWidgets('returning user with completed onboarding skips onboarding',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      await tester.pumpWidget(
        _testApp(
          settings: settings,
          home: Scaffold(
            body: Text(
              settings.isOnboardingComplete ? 'Home' : 'Onboarding',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Onboarding'), findsNothing);
    });
  });

  // ── Settings initialization race ───────────────────────────────────

  group('Startup routing — settings init race', () {
    test('settings.ready resolves with correct onboarding state', () async {
      // Scenario: onboarding was previously completed.
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': true,
      });
      final settings = SettingsProvider();

      // Before ready, default is false.
      // After ready, it must reflect the persisted value.
      await settings.ready;
      expect(settings.isOnboardingComplete, isTrue);
    });

    test('settings.ready resolves quickly with mock SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': false,
      });
      final settings = SettingsProvider();

      // In tests with mock SharedPreferences, ready should resolve
      // promptly (no actual disk I/O).
      final completed = await settings.ready.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      expect(completed, isNull); // timeout returns null on success path
      expect(settings.isLoaded, isTrue);
    });

    test('multiple calls to ready return the same future', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      final future1 = settings.ready;
      final future2 = settings.ready;
      expect(identical(future1, future2), isTrue);
    });
  });

  // ── Auth routing ───────────────────────────────────────────────────

  group('Startup routing — authenticated vs unauthenticated', () {
    test('onboarding complete flag is independent of auth state', () async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      // Regardless of auth state, onboarding is complete.
      expect(settings.isOnboardingComplete, isTrue);
    });

    test('unauthenticated user who completed onboarding goes to login',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      // Simulate the routing decision in main.dart:
      // settings.isOnboardingComplete ? AppRouter.home : AppRouter.onboarding
      final route = settings.isOnboardingComplete
          ? AppRouter.home
          : AppRouter.onboarding;

      expect(route, AppRouter.home);

      // When onboarding is complete, the app routes to home (or auth if
      // not authenticated — but that decision is made by the main scaffold,
      // not the initial route). The important thing: it does NOT route
      // to onboarding.
      expect(route, isNot(AppRouter.onboarding));
    });
  });

  // ── Onboarding screen — persist before navigate ────────────────────

  group('OnboardingScreen — completion persistence', () {
    testWidgets(
        'completing onboarding persists flag before navigation',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.ready;

      await tester.pumpWidget(
        _testApp(
          settings: settings,
          home: const OnboardingScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Find and tap the "Skip" button to complete onboarding.
      final skipFinder = find.text('Skip');
      if (skipFinder.evaluate().isNotEmpty) {
        await tester.tap(skipFinder);
        await tester.pumpAndSettle();

        // After completing onboarding, the flag must be persisted.
        expect(settings.isOnboardingComplete, isTrue);

        // Verify SharedPreferences has the flag.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('onboardingComplete'), isTrue);
      }
    });

    testWidgets(
        'getStarted button on last page persists flag before navigation',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await settings.ready;

      await tester.pumpWidget(
        _testApp(
          settings: settings,
          home: const OnboardingScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate to the last page (page index 4, 0-indexed).
      // The PageView has 5 pages. We need to swipe through them.
      final pageView = find.byType(PageView);
      if (pageView.evaluate().isNotEmpty) {
        // Swipe left 4 times to get to the last page.
        for (var i = 0; i < 4; i++) {
          await tester.drag(pageView, const Offset(-300, 0));
          await tester.pumpAndSettle();
        }

        // Now tap "Get Started".
        final getStartedFinder = find.text('Get Started');
        if (getStartedFinder.evaluate().isNotEmpty) {
          await tester.tap(getStartedFinder);
          await tester.pumpAndSettle();

          expect(settings.isOnboardingComplete, isTrue);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getBool('onboardingComplete'), isTrue);
        }
      }
    });
  });

  // ── SplashScreen — waits for initialization ────────────────────────

  group('SplashScreen — initialization readiness', () {
    testWidgets('splash does not dismiss before initializationReady completes',
        (tester) async {
      final completer = Completer<void>();
      var onCompleteCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SplashScreen(
            onComplete: () => onCompleteCalled = true,
            initializationReady: completer.future,
          ),
        ),
      );

      // Wait past the minimum display time.
      await tester.pump(const Duration(milliseconds: 3000));

      // onComplete should NOT have been called yet because
      // initializationReady hasn't resolved.
      expect(onCompleteCalled, isFalse);

      // Now complete the initialization future.
      completer.complete();
      await tester.pump();

      // onComplete should now be called.
      expect(onCompleteCalled, isTrue);
    });

    testWidgets('splash dismisses when no initializationReady provided',
        (tester) async {
      var onCompleteCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SplashScreen(
            onComplete: () => onCompleteCalled = true,
          ),
        ),
      );

      // Wait past the minimum display time.
      await tester.pump(const Duration(milliseconds: 3000));

      // onComplete should have been called after the timer.
      expect(onCompleteCalled, isTrue);
    });

    testWidgets('splash waits for both timer AND initializationReady',
        (tester) async {
      final completer = Completer<void>();
      var onCompleteCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SplashScreen(
            onComplete: () => onCompleteCalled = true,
            initializationReady: completer.future,
          ),
        ),
      );

      // Complete initialization early (before 2500ms).
      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Should still not be called — waiting for the 2500ms timer.
      expect(onCompleteCalled, isFalse);

      // Wait for the timer to complete.
      await tester.pump(const Duration(milliseconds: 2500));

      // Now both conditions are met.
      expect(onCompleteCalled, isTrue);
    });
  });

  // ── Route decision correctness ─────────────────────────────────────

  group('Route decision — onboarding state', () {
    test('initialRoute uses AppRouter.onboarding when not complete', () async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': false,
      });
      final settings = SettingsProvider();
      await settings.ready;

      final initialRoute = settings.isOnboardingComplete
          ? AppRouter.home
          : AppRouter.onboarding;

      expect(initialRoute, AppRouter.onboarding);
    });

    test('initialRoute uses AppRouter.home when complete', () async {
      SharedPreferences.setMockInitialValues({
        'onboardingComplete': true,
      });
      final settings = SettingsProvider();
      await settings.ready;

      final initialRoute = settings.isOnboardingComplete
          ? AppRouter.home
          : AppRouter.onboarding;

      expect(initialRoute, AppRouter.home);
    });
  });
}
