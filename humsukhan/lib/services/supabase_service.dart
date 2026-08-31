import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/env_config.dart';

/// Singleton wrapper around the Supabase Flutter client.
///
/// Exposes a [status] field so the UI and other services can distinguish
/// between *not configured*, *initialization failed*, and *ready*.
///
/// Backward-compatible public API:
///   - [isReady]        – `true` when the client is initialised.
///   - [hasConfiguration] – `true` when URL + publishable key are present.
///   - [client]         – nullable [SupabaseClient].
///   - [auth]           – nullable [GoTrueClient].
class SupabaseService {
  static SupabaseService? _instance;
  static SupabaseService get instance => _instance ??= SupabaseService._();
  SupabaseService._();

  bool _initialized = false;
  SupabaseConfigStatus _status = SupabaseConfigStatus.missingKey;
  String? _errorMessage;

  // ── Status helpers ────────────────────────────────────────────────

  /// Current configuration / initialisation status.
  SupabaseConfigStatus get status => _status;

  /// Human-readable description of the current status, suitable for
  /// debug overlays or developer settings screens.
  String get statusDescription {
    switch (_status) {
      case SupabaseConfigStatus.ready:
        return 'Supabase is configured and ready.';
      case SupabaseConfigStatus.configured:
        return 'Supabase is configured and ready.';
      case SupabaseConfigStatus.missingKey:
        return 'Supabase publishable key not supplied. '
            'Pass SUPABASE_URL and SUPABASE_ANON_KEY via --dart-define.';
      case SupabaseConfigStatus.failed:
        return 'Supabase initialization failed: ${_errorMessage ?? "unknown error"}';
    }
  }

  /// Non-null error message when [status] is [SupabaseConfigStatus.failed].
  String? get errorMessage => _errorMessage;

  /// `true` once Supabase has been successfully initialised.
  bool get isReady =>
      _status == SupabaseConfigStatus.ready ||
      _status == SupabaseConfigStatus.configured;

  /// `true` when both URL and a safe publishable key are present.
  bool get hasConfiguration => EnvConfig.hasSupabaseConfig;

  // ── Client accessors ─────────────────────────────────────────────

  /// Returns the [SupabaseClient] or `null` if not ready.
  SupabaseClient? get client {
    if (!isReady) return null;
    try {
      return Supabase.instance.client;
    } catch (e) {
      debugPrint('SupabaseService client error: $e');
      return null;
    }
  }

  /// Returns the [GoTrueClient] or `null` if not ready.
  GoTrueClient? get auth => client?.auth;

  User? get currentUser => auth?.currentUser;
  bool get isAuthenticated => currentUser != null;
  String get userId => currentUser?.id ?? '';
  Stream<AuthState> get onAuthStateChange =>
      auth?.onAuthStateChange ?? const Stream.empty();

  // ── Initialisation ───────────────────────────────────────────────

  /// Initialise the Supabase client.
  ///
  /// Safe to call more than once — subsequent calls are no-ops.
  /// Sets [status] to [SupabaseConfigStatus.ready] on success,
  /// [SupabaseConfigStatus.missingKey] when keys are absent, or
  /// [SupabaseConfigStatus.failed] on error.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Guard: reject service_role / sb_secret keys in debug builds.
    assert(
      !EnvConfig.isServiceRoleKey(EnvConfig.supabaseAnonKey),
      '❌ SUPABASE_ANON_KEY contains a service_role or sb_secret key. '
      'Never embed admin keys in the Flutter client. '
      'Use the publishable (anon) key from your Supabase project settings.',
    );

    if (!EnvConfig.hasSupabaseConfig) {
      _status = SupabaseConfigStatus.missingKey;
      _errorMessage = EnvConfig.supabaseUrl.isEmpty
          ? 'SUPABASE_URL is not set. '
              'Pass it via --dart-define=SUPABASE_URL=...'
          : 'SUPABASE_ANON_KEY is missing or is a service-role key. '
              'Pass the publishable key via --dart-define=SUPABASE_ANON_KEY=...';
      debugPrint(
        '[SupabaseService] ⚠ $_errorMessage',
      );
      return;
    }

    try {
      await Supabase.initialize(
        url: EnvConfig.supabaseUrl,
        publishableKey: EnvConfig.supabaseAnonKey,
        debug: kDebugMode,
      );
      _status = SupabaseConfigStatus.ready;
      debugPrint('[SupabaseService] ✓ Initialized successfully.');
    } catch (e) {
      _status = SupabaseConfigStatus.failed;
      _errorMessage = e.toString();
      debugPrint('[SupabaseService] ✗ Initialization failed: $e');
    }
  }
}
