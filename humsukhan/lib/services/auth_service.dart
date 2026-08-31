import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'database_service.dart';
import '../models/models.dart';
import 'supabase_service.dart';

/// Authentication service wrapping Supabase GoTrue.
///
/// Handles sign-up, sign-in, sign-out, password reset, and profile repair.
/// Email verification is handled transparently: if Supabase requires email
/// confirmation, the service attempts an automatic sign-in after account
/// creation and surfaces a clear error if verification is still pending.
class AuthService {
  static AuthService? _instance;
  static AuthService get instance => _instance ??= AuthService._();
  AuthService._();

  SupabaseService get _supabase => SupabaseService.instance;
  bool get isAvailable => _supabase.auth != null;
  User? get currentUser => _supabase.currentUser;
  bool get isAuthenticated => _supabase.isAuthenticated;
  Stream<AuthState> get onAuthStateChange => _supabase.onAuthStateChange;

  // ── Password validation ─────────────────────────────────────────────

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

  // ── Sign Up ─────────────────────────────────────────────────────────

  /// Create a new Supabase Auth user and ensure a matching profiles row.
  ///
  /// If Supabase requires email verification the session will be `null`
  /// after `signUp`.  In that case we immediately attempt `signIn`.  If
  /// sign-in also fails (because the email is not yet confirmed) we return
  /// a clear actionable error – we never show a blocking "please verify
  /// your email" screen.
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

      // ── Email verification handling ───────────────────────────────
      // When Supabase has email confirmation enabled, signUp returns
      // a user object but a null session.  We try to sign in immediately
      // so the user gets a usable session without manual verification.
      if (response.session == null) {
        debugPrint(
          '[AuthService] signUp returned null session – '
          'attempting automatic signIn for $email',
        );
        final signInResult = await signIn(email: email, password: password);
        if (signInResult.success) {
          // Sign-in succeeded — the user is verified and authenticated.
          await _ensureProfile(signInResult.user!, name: name);
          return signInResult;
        }
        // Sign-in failed — email verification is still pending.
        return AuthResult.failure(
          'Account created, but email verification is required. '
          'Please check your inbox and verify your email, then sign in.',
        );
      }

      // ── Session is available — user is authenticated ──────────────
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

  // ── Sign In ─────────────────────────────────────────────────────────

  /// Sign in with email and password.
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
        // Ensure the profiles row exists (repair if trigger missed).
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

  // ── Sign Out ────────────────────────────────────────────────────────

  Future<void> signOut() async {
    if (!isAvailable) return;
    try {
      await _supabase.auth!.signOut();
    } catch (e) {
      debugPrint('Sign out error: $e');
    }
  }

  // ── Password Reset ──────────────────────────────────────────────────

  Future<bool> resetPassword(String email) async {
    if (!isAvailable) return false;
    try {
      await _supabase.auth!.resetPasswordForEmail(email);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Profile Repair ──────────────────────────────────────────────────

  /// Ensure a `profiles` row exists for [user].
  ///
  /// The `on_auth_user_created` database trigger should handle this
  /// automatically, but if the trigger is missing, disabled, or fails,
  /// this method creates the row client-side so the app is never left
  /// with an authenticated user that has no profile.
  Future<void> _ensureProfile(User user, {String? name}) async {
    try {
      final existing =
          await DatabaseService.instance.fetchProfile(user.id);
      if (existing != null) return; // Profile already exists.

      final profileName =
          name?.isNotEmpty == true ? name! : 'User';
      await DatabaseService.instance.upsertProfile(
        UserProfile(id: user.id, name: profileName),
      );
      debugPrint('[AuthService] Repaired missing profile for ${user.id}');
    } catch (e) {
      // Profile repair is best-effort.  A missing profile should not
      // block authentication.
      debugPrint('[AuthService] Profile repair failed: $e');
    }
  }
}

/// Result of an authentication operation.
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
