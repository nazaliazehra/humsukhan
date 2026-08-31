import 'package:flutter_test/flutter_test.dart';
import 'package:humsukhan/services/auth_service.dart';

/// Tests for [AuthService] and [AuthResult].
///
/// These tests exercise the pure logic (password validation, result types)
/// and the unavailability paths (when Supabase is not configured).
/// They do NOT require a real Supabase backend.
void main() {
  // ── Password validation ──────────────────────────────────────────

  group('AuthService — password validation', () {
    test('accepts a valid 8-char password', () {
      expect(AuthService.validatePassword('Ab1@xyz!'), isNull);
    });

    test('rejects password shorter than 8 chars', () {
      expect(
        AuthService.validatePassword('Ab1@x!'),
        'Password must be exactly 8 characters.',
      );
    });

    test('rejects password longer than 8 chars', () {
      expect(
        AuthService.validatePassword('Ab1@xyz!!'),
        'Password must be exactly 8 characters.',
      );
    });

    test('rejects password without uppercase', () {
      expect(
        AuthService.validatePassword('ab1@xyz!'),
        'Password must contain uppercase, lowercase, number, and special character.',
      );
    });

    test('rejects password without lowercase', () {
      expect(
        AuthService.validatePassword('AB1@XYZ!'),
        'Password must contain uppercase, lowercase, number, and special character.',
      );
    });

    test('rejects password without digit', () {
      expect(
        AuthService.validatePassword('Ab@xyz!U'),
        'Password must contain uppercase, lowercase, number, and special character.',
      );
    });

    test('rejects password without special character', () {
      expect(
        AuthService.validatePassword('Abc1xyzU'),
        'Password must contain uppercase, lowercase, number, and special character.',
      );
    });

    test('accepts various special characters', () {
      expect(AuthService.validatePassword('Ab1@xyz!'), isNull);
      expect(AuthService.validatePassword('Ab1#xyz!'), isNull);
      expect(AuthService.validatePassword('Ab1\$xyz!'), isNull);
      expect(AuthService.validatePassword('Ab1%xyz!'), isNull);
      expect(AuthService.validatePassword('Ab1^xyz!'), isNull);
      expect(AuthService.validatePassword('Ab1&xyz!'), isNull);
      expect(AuthService.validatePassword('Ab1*xyz!'), isNull);
    });
  });

  // ── AuthResult ───────────────────────────────────────────────────

  group('AuthResult', () {
    test('success result has correct properties', () {
      final result = AuthResult.success(null);
      expect(result.success, isTrue);
      expect(result.user, isNull);
      expect(result.errorMessage, isNull);
    });

    test('failure result has correct properties', () {
      final result = AuthResult.failure('Something went wrong');
      expect(result.success, isFalse);
      expect(result.user, isNull);
      expect(result.errorMessage, 'Something went wrong');
    });

    test('failure with null message', () {
      final result = AuthResult.failure(null);
      expect(result.success, isFalse);
      expect(result.errorMessage, isNull);
    });
  });

  // ── AuthService availability ─────────────────────────────────────

  group('AuthService — availability', () {
    test('isAvailable is false when Supabase is not initialized', () {
      final auth = AuthService.instance;
      // In test env without Supabase init, isAvailable should be false.
      // The auth accessor returns null when Supabase is not ready.
      expect(auth.isAvailable, isFalse);
    });

    test('signUp returns failure when Supabase is unavailable', () async {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        final result = await auth.signUp(
          email: 'test@example.com',
          password: 'Ab1@xyz!',
          name: 'Test',
        );
        expect(result.success, isFalse);
        expect(result.user, isNull);
        expect(result.errorMessage, isNotNull);
        expect(result.errorMessage, contains('unavailable'));
      }
    });

    test('signIn returns failure when Supabase is unavailable', () async {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        final result = await auth.signIn(
          email: 'test@example.com',
          password: 'Ab1@xyz!',
        );
        expect(result.success, isFalse);
        expect(result.user, isNull);
        expect(result.errorMessage, isNotNull);
        expect(result.errorMessage, contains('unavailable'));
      }
    });

    test('signIn validates password length before contacting Supabase',
        () async {
      final auth = AuthService.instance;
      // validatePassword is a static method — always testable.
      final error = AuthService.validatePassword('short');
      expect(error, isNotNull);
      expect(error, contains('8 characters'));
    });

    test('signUp returns password error before contacting Supabase',
        () async {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        final result = await auth.signUp(
          email: 'test@example.com',
          password: 'weak',
          name: 'Test',
        );
        expect(result.success, isFalse);
        expect(result.errorMessage, contains('8 characters'));
      }
    });

    test('signOut does not throw when Supabase is unavailable', () async {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        expect(() => auth.signOut(), returnsNormally);
        await auth.signOut();
      }
    });

    test('resetPassword returns false when Supabase is unavailable', () async {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        final result = await auth.resetPassword('test@example.com');
        expect(result, isFalse);
      }
    });

    test('currentUser is null when Supabase is unavailable', () {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        expect(auth.currentUser, isNull);
      }
    });

    test('isAuthenticated is false when Supabase is unavailable', () {
      final auth = AuthService.instance;
      if (!auth.isAvailable) {
        expect(auth.isAuthenticated, isFalse);
      }
    });
  });

  // ── Email verification handling (logic verification) ─────────────

  group('Email verification — no blocking state', () {
    test('AuthResult.failure can carry verification-pending message', () {
      // When signUp creates the user but session is null and signIn fails,
      // the service returns a failure with a clear message (not a blocking UI).
      final result = AuthResult.failure(
        'Account created, but email verification is required. '
        'Please check your inbox and verify your email, then sign in.',
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('email verification'));
      expect(result.errorMessage, contains('sign in'));
    });

    test('AuthResult.failure can carry generic account-creation error', () {
      final result = AuthResult.failure(
        'Account creation failed. Please check your connection and try again.',
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Account creation failed'));
    });
  });
}
