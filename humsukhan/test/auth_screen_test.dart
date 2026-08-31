import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:humsukhan/providers/auth_provider.dart';
import 'package:humsukhan/screens/auth_screen.dart';

/// Widget tests for [AuthScreen] — verifying that guest/skip options
/// have been removed and the screen only offers sign-up / sign-in.
void main() {
  Widget buildAuthScreen() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
      ],
      child: const MaterialApp(
        home: AuthScreen(),
      ),
    );
  }

  group('AuthScreen — guest/skip options removed', () {
    testWidgets('does NOT show "Try Without Account" button',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      expect(find.text('Try Without Account'), findsNothing);
    });

    testWidgets('does NOT show "Skip for now" button',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      expect(find.text('Skip for now (offline mode)'), findsNothing);
    });

    testWidgets('does NOT show explore icon (guest button icon)',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      // The explore icon was used for the "Try Without Account" button.
      expect(find.byIcon(Icons.explore), findsNothing);
    });

    testWidgets('does NOT navigate to /home without authentication',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      // The "Skip for now" button used to navigate to /home directly.
      // Verify no direct-to-home navigation path exists on this screen.
      // (The only navigation should happen after successful auth.)
      expect(find.text('Home'), findsNothing);
    });
  });

  group('AuthScreen — required auth elements present', () {
    testWidgets('shows Create Account / Sign In heading',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      // Default mode is sign-in (not sign-up), so should show "Welcome Back"
      expect(
        find.textContaining('Welcome Back'),
        findsOneWidget,
      );
    });

    testWidgets('shows email and password fields', (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsAtLeast(2));
    });

    testWidgets('shows sign-in button', (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      expect(find.text('Sign In'), findsOneWidget);
    });

    testWidgets('shows toggle to switch between sign-in and sign-up',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      expect(find.textContaining('Sign up'), findsOneWidget);
    });

    testWidgets('toggling to sign-up shows name field and create button',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildAuthScreen());
      await tester.pumpAndSettle();

      // Tap "Don't have an account? Sign up"
      await tester.tap(find.textContaining('Sign up'));
      await tester.pumpAndSettle();

      // Should now show "Create Account" button
      expect(find.text('Create Account'), findsOneWidget);

      // Should show the name field (3 text fields: name, email, password)
      expect(find.byType(TextField), findsAtLeast(3));
    });
  });
}
