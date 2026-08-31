import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Persistent, user-scoped store for environmental alert history.
///
/// Alerts are stored as a JSON array in SharedPreferences under the key
/// `alert_history_<userId>`.  An anonymous (non-signed-in) user is
/// identified by the string `'anonymous'`.
///
/// A maximum of [maxHistorySize] entries is enforced — oldest entries are
/// silently trimmed when the limit is exceeded.
class AlertHistoryStore {
  static const int maxHistorySize = 100;
  static const _keyPrefix = 'alert_history_';

  String _userId = 'anonymous';
  List<SoundEvent> _events = [];
  bool _loaded = false;

  /// Returns the in-memory list.  Call [load] before first use.
  List<SoundEvent> get events => List.unmodifiable(_events);

  /// Whether history has been loaded for the current user.
  bool get isLoaded => _loaded;

  /// Set the active user and load their history from local storage.
  /// Calling this resets the in-memory list and re-reads from disk.
  Future<void> setUser(String userId) async {
    _userId = userId.isNotEmpty ? userId : 'anonymous';
    await load();
  }

  /// Read the persisted history from SharedPreferences.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_keyPrefix$_userId');
      if (raw == null || raw.isEmpty) {
        _events = [];
      } else {
        final list = jsonDecode(raw) as List<dynamic>;
        _events = list
            .map((e) => SoundEvent.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('AlertHistoryStore load error: $e');
      _events = [];
    }
    _loaded = true;
  }

  /// Persist the current in-memory list to SharedPreferences.
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_events.map((e) => e.toJson()).toList());
      await prefs.setString('$_keyPrefix$_userId', json);
    } catch (e) {
      debugPrint('AlertHistoryStore save error: $e');
    }
  }

  /// Append an event and trim to [maxHistorySize].
  /// Returns the updated list.
  Future<void> addEvent(SoundEvent event) async {
    _events.add(event);
    _trimExcess();
    await save();
  }

  /// Mark the event with [eventId] as dismissed.
  /// Returns `true` if the event was found and updated.
  Future<bool> dismiss(String eventId) async {
    final idx = _events.indexWhere((e) => e.id == eventId);
    if (idx == -1) return false;
    _events[idx] = _events[idx].copyWith(dismissed: true);
    await save();
    return true;
  }

  /// Remove all events from both memory and disk.
  Future<void> clear() async {
    _events.clear();
    await save();
  }

  /// Remove dismissed events older than [olderThan] (optional).
  Future<int> pruneDismissed({Duration? olderThan}) async {
    final cutoff = olderThan != null
        ? DateTime.now().subtract(olderThan)
        : DateTime.now().add(const Duration(days: 1)); // keep none dismissed
    final before = _events.length;
    _events.removeWhere(
        (e) => e.dismissed && e.timestamp.isBefore(cutoff));
    if (_events.length != before) await save();
    return before - _events.length;
  }

  void _trimExcess() {
    while (_events.length > maxHistorySize) {
      _events.removeAt(0);
    }
  }
}
