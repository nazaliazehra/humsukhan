import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'database_service.dart';
import '../models/models.dart';
import 'supabase_service.dart';

/// Authentication service wrapping Supabase GoTrue.
///
/// Handles sign-up, sign-in, sign-out, password reset, anonymous sign-in,
/// and profile repair. Email confirmation is intentionally not handled in the
/// client flow; the Supabase project should have Confirm email disabled so
/// sign-up returns an authenticated session immediately.
class AuthService {
  static AuthService? _instance;
  static AuthService get instance => _instance ??= AuthService._();
  AuthService._();

  SupabaseService get _supabase => SupabaseService.instance;
  bool get isAvailable => _supabase.auth != null;
  User? get currentUser => _supabase.currentUser;
  bool get isAuthenticated => _supabase.isAuthenticated;
  Stream<AuthState> get onAuthStateChange => _supabase.onAuthStateChange;

  static final RegExp _strongEightCharPassword =
      RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^A-Za-z0-9]).{8}$');

  static String? validatePassword(String password) {
    if (password.length != 8) {
      return 'Password must be exactly 8 characters.';
    }
    if (!_strongEightCharPassword.hasMatch(password)) {
      return 'Password must contain uppercase, lowercase, number, and special character.';
    }
    return null;
  }

  Future<AuthResult> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    if (!isAvailable) {
      return AuthResult.failure(
        'Authentication unavailable. Please check your connection and try again.',
      );
    }

    final validationError = validatePassword(password);
    if (validationError != null) {
      return AuthResult.failure(validationError);
    }

    try {
      final response = await _supabase.auth!.signUp(
        email: email,
        password: password,
        data: name != null && name.isNotEmpty ? {'name': name} : null,
      );

      final user = response.user;
      if (user == null) {
        return AuthResult.failure('Account creation failed: no user returned.');
      }

      // With Supabase "Confirm email" disabled, signUp returns a session
      // immediately. The profile trigger and _ensureProfile() both protect
      // against a missing public profile row.
      if (response.session == null) {
        return AuthResult.failure(
          'Account was created, but the Supabase project still requires email confirmation. '
          'Disable "Confirm email" in Supabase Authentication settings.',
        );
      }

      await _ensureProfile(user, name: name);
      return AuthResult.success(user);
    } on AuthException catch (e) {
      return AuthResult.failure(e.message);
    } catch (e) {
      debugPrint('[AuthService] signUp unexpected error: $e');
      return AuthResult.failure(
        'Account creation failed. Please check your connection and try again.',
      );
    }
  }

  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    if (!isAvailable) {
      return AuthResult.failure(
        'Authentication unavailable. Please check your connection and try again.',
      );
    }
    try {
      final response = await _supabase.auth!.signInWithPassword(
        email: email,
        password: password,
      );
      if (response.user != null) {
        await _ensureProfile(response.user!);
        return AuthResult.success(response.user!);
      }
      return AuthResult.failure('Sign in failed: no user returned.');
    } on AuthException catch (e) {
      return AuthResult.failure(e.message);
    } catch (e) {
      debugPrint('[AuthService] signIn unexpected error: $e');
      return AuthResult.failure('Sign in failed. Please try again.');
    }
  }

  /// Sign in anonymously for users who want to try the app without an account.
  Future<AuthResult> signInAnonymously() async {
    if (!isAvailable) {
      return AuthResult.failure(
        'Authentication unavailable. Please check your connection and try again.',
      );
    }
    try {
      final response = await _supabase.auth!.signInAnonymously();
      final user = response.user;
      if (user == null) {
        return AuthResult.failure('Anonymous sign in failed: no user returned.');
      }
      await _ensureProfile(user, name: 'Guest');
      return AuthResult.success(user);
    } on AuthException catch (e) {
      return AuthResult.failure(e.message);
    } catch (e) {
      debugPrint('[AuthService] anonymous signIn unexpected error: $e');
      return AuthResult.failure('Guest sign in failed. Please try again.');
    }
  }

  Future<void> signOut() async {
    if (!isAvailable) return;
    try {
      await _supabase.auth!.signOut();
    } catch (e) {
      debugPrint('Sign out error: $e');
    }
  }

  Future<bool> resetPassword(String email) async {
    if (!isAvailable) return false;
    try {
      await _supabase.auth!.resetPasswordForEmail(email);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureProfile(User user, {String? name}) async {
    try {
      final existing = await DatabaseService.instance.fetchProfile(user.id);
      if (existing != null) return;

      final profileName = name?.isNotEmpty == true ? name! : 'User';
      await DatabaseService.instance.upsertProfile(
        UserProfile(id: user.id, name: profileName),
      );
      debugPrint('[AuthService] Repaired missing profile for ${user.id}');
    } catch (e) {
      debugPrint('[AuthService] Profile repair failed: $e');
    }
  }
}

class AuthResult {
  final bool success;
  final User? user;
  final String? errorMessage;

  AuthResult.success(this.user)
      : success = true,
        errorMessage = null;

  AuthResult.failure(this.errorMessage)
      : success = false,
        user = null;
}
