import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_service.dart';

/// Central abstraction for user-scoped local data persistence.
///
/// User-owned data keys (profile, sessions, conversations, quick replies, …)
/// are automatically prefixed with the authenticated user's ID so that local
/// data from different accounts never leaks into each other's scope.
///
/// Anonymous Supabase users receive their own scope keyed by their UUID.
/// A fully unauthenticated session (no Supabase user at all) falls back to
/// the shared `'anonymous'` bucket.
///
/// Global (non-user-specific) preferences such as theme, language, and alert
/// policy remain under their plain key names — use [rawKey] or the normal
/// [SharedPreferences] API for those.
class ScopedPreferences {
  static ScopedPreferences? _instance;
  static ScopedPreferences get instance => _instance ??= ScopedPreferences._();
  ScopedPreferences._();

  static const _migrationFlag = '_keyMigrationDone';
  static const String _anonymousId = 'anonymous';

  String _userId = _anonymousId;

  /// The user ID currently used for key scoping.
  String get currentUserId => _userId;

  /// Call once after `SupabaseService.instance.initialize()` completes.
  Future<void> initialize() async {
    final rawId = SupabaseService.instance.userId;
    _userId = rawId.isNotEmpty ? rawId : _anonymousId;
    await _runMigration();
  }

  // ── Key helpers ─────────────────────────────────────────────────────

  /// Returns [key] prefixed with the current user scope.
  ///
  /// ```dart
  /// scopedKey('userProfile') → 'user_<uuid>_userProfile'
  /// ```
  String scopedKey(String key) => 'user_${_userId}_$key';

  /// Read a scoped string value.
  Future<String?> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(scopedKey(key));
  }

  /// Write a scoped string value.
  Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(scopedKey(key), value);
  }

  // ── Auth-change lifecycle ──────────────────────────────────────────

  /// Switch the active scope to [newUserId].
  ///
  /// Any previously-scoped in-memory state in providers should be persisted
  /// *before* calling this method (the old scope becomes unreachable through
  /// [scopedKey] once the ID changes).
  Future<void> setUser(String newUserId) async {
    _userId = newUserId.isNotEmpty ? newUserId : _anonymousId;
  }

  /// Delete only the current user's scoped keys — global app preferences
  /// (theme, language, onboarding, alert policy) are preserved.
  Future<void> clearCurrentUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'user_${_userId}_';
    final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  // ── One-time migration ─────────────────────────────────────────────

  /// Keys that held user-specific data before scoping was introduced.
  static const _legacyKeys = {
    'userProfile',
    'professionalSessions',
    'professionalFolders',
    'professionalInsights',
    'everydayConversations',
    'quickReplies',
  };

  /// Move unscoped legacy keys under the current user's scope.
  ///
  /// Safe to call more than once — only unscoped keys that still exist and
  /// whose scoped counterpart does *not* already exist are migrated.
  Future<void> runMigration() => _runMigration();

  Future<void> _runMigration() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationFlag) ?? false) return;

    final uid = SupabaseService.instance.userId;
    if (uid.isEmpty) {
      // No authenticated user yet — defer migration until sign-in.
      return;
    }

    final scope = 'user_$uid';

    for (final key in _legacyKeys) {
      if (!prefs.containsKey(key)) continue;

      final scoped = '${scope}_$key';
      // Never overwrite data already present in the scoped slot.
      if (prefs.containsKey(scoped)) {
        await prefs.remove(key);
        continue;
      }

      final strVal = prefs.getString(key);
      if (strVal != null) {
        await prefs.setString(scoped, strVal);
        await prefs.remove(key);
        continue;
      }

      final boolVal = prefs.getBool(key);
      if (boolVal != null) {
        await prefs.setBool(scoped, boolVal);
        await prefs.remove(key);
        continue;
      }

      final intVal = prefs.getInt(key);
      if (intVal != null) {
        await prefs.setInt(scoped, intVal);
        await prefs.remove(key);
        continue;
      }

      final doubleVal = prefs.getDouble(key);
      if (doubleVal != null) {
        await prefs.setDouble(scoped, doubleVal);
        await prefs.remove(key);
        continue;
      }
    }

    await prefs.setBool(_migrationFlag, true);
    debugPrint('[ScopedPreferences] Legacy key migration complete for $scope');
  }
}
