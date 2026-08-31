import 'dart:convert';

/// Supabase configuration status.
enum SupabaseConfigStatus {
  configured,
  missingKey,
  failed,
  ready,
}

/// Centralized environment configuration.
///
/// Build-time dart-defines can override these defaults. The bundled Supabase
/// client key is intentionally the project's publishable/anon key, which is
/// safe for a client application when RLS is correctly configured.
class EnvConfig {
  EnvConfig._();

  /// HumSukhan Supabase project URL.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://dhlptghfyfrzogurruid.supabase.co',
  );

  /// HumSukhan Supabase publishable/anon key.
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRobHB0Z2hmeWZyem9ndXJydWlkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTMxMTgsImV4cCI6MjEwMzc2OTExOH0.qQ4ES0hixQfy2VKj-8iqf7JBHnWZ14qG8JqLR3SIXwQ',
  );

  static const int maxRetentionDays = 15;

  /// Returns true when [key] looks like a service-role or secret key.
  static bool isServiceRoleKey(String key) {
    if (key.isEmpty) return false;
    if (key.contains('c2VydmljZV9yb2xl')) return true;
    try {
      final segments = key.split('.');
      if (segments.length >= 2) {
        for (final segment in segments.sublist(0, 2)) {
          var b64 = segment.replaceAll('-', '+').replaceAll('_', '/');
          while (b64.length % 4 != 0) {
            b64 += '=';
          }
          final decoded = String.fromCharCodes(base64Decode(b64));
          if (decoded.contains('service_role') || decoded.contains('sb_secret')) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static bool get hasSupabaseConfig =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.trim().isNotEmpty &&
      !isServiceRoleKey(supabaseAnonKey);
}
