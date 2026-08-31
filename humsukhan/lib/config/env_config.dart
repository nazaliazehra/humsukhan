import 'dart:convert';

/// Supabase configuration status.
///
/// Allows UI and services to distinguish between:
/// - [configured]  – keys present, initialization succeeded
/// - [missingKey]  – no publishable key supplied at build time
/// - [failed]      – initialization threw an error
/// - [ready]       – alias for [configured]; client is usable
enum SupabaseConfigStatus {
  configured,
  missingKey,
  failed,
  ready,
}

/// Centralized environment configuration.
///
/// All secrets are supplied at build time via `--dart-define` or
/// `--dart-define-from-file`. Never hardcode real keys in source.
///
/// ```bash
/// # Single-value injection
/// flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co \
///             --dart-define=SUPABASE_ANON_KEY=eyJ...
///
/// # File-based injection (one KEY=VALUE per line, no quotes required)
/// flutter run --dart-define-from-file=.env
/// ```
class EnvConfig {
  EnvConfig._();

  /// Supabase project URL — supply via `--dart-define=SUPABASE_URL=...`.
  static const String supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');

  /// Supabase publishable (anon) key — supply via
  /// `--dart-define=SUPABASE_ANON_KEY=...`.
  static const String supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  static const int maxRetentionDays = 15;

  /// Returns `true` when [key] looks like a Supabase `service_role` or
  /// `sb_secret` JWT. These keys must never be used in the Flutter client.
  ///
  /// Supabase JWTs are Base64-encoded JSON; the service_role payload
  /// contains `"role":"service_role"`. We check the raw string for that
  /// Base64 fragment as well as the decoded claim.
  static bool isServiceRoleKey(String key) {
    if (key.isEmpty) return false;
    // Base64 of `"role":"service_role"` contains this substring.
    if (key.contains('c2VydmljZV9yb2xl')) return true;
    // Belt-and-suspenders: decode each JWT segment and inspect.
    try {
      final segments = key.split('.');
      if (segments.length >= 2) {
        for (final segment in segments.sublist(0, 2)) {
          // Normalize Base64 URL-safe characters and padding.
          var b64 = segment.replaceAll('-', '+').replaceAll('_', '/');
          while (b64.length % 4 != 0) {
            b64 += '=';
          }
          final decoded = String.fromCharCodes(
            base64Decode(b64),
          );
          if (decoded.contains('service_role') ||
              decoded.contains('sb_secret')) {
            return true;
          }
        }
      }
    } catch (_) {
      // Malformed JWT — not a recognised service-role token.
    }
    return false;
  }

  /// `true` when both [supabaseUrl] and [supabaseAnonKey] are non-empty
  /// and the key is not a dangerous service-role key.
  static bool get hasSupabaseConfig =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.trim().isNotEmpty &&
      !isServiceRoleKey(supabaseAnonKey);
}
