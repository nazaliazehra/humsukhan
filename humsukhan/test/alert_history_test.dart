import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:humsukhan/models/models.dart';
import 'package:humsukhan/services/alert_history_store.dart';

/// Tests for [AlertHistoryStore] — the persistent, user-scoped store for
/// environmental alert history.
///
/// Uses SharedPreferences mock (setMockInitialValues) for deterministic
/// local-storage behaviour without real disk I/O.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ── Construction ───────────────────────────────────────────────────

  group('AlertHistoryStore — construction', () {
    test('starts empty before load', () {
      final store = AlertHistoryStore();
      expect(store.events, isEmpty);
      expect(store.isLoaded, isFalse);
    });

    test('load on empty storage yields empty list', () async {
      final store = AlertHistoryStore();
      await store.setUser('user1');
      expect(store.events, isEmpty);
      expect(store.isLoaded, isTrue);
    });
  });

  // ── User scoping ──────────────────────────────────────────────────

  group('AlertHistoryStore — user scoping', () {
    test('different users have separate histories', () async {
      final store = AlertHistoryStore();

      // Add event for user1.
      await store.setUser('user1');
      await store.addEvent(SoundEvent(type: 'Fire Alarm', confidence: 0.9));
      expect(store.events, hasLength(1));

      // Switch to user2 — should be empty.
      await store.setUser('user2');
      expect(store.events, isEmpty);

      // Add event for user2.
      await store.addEvent(SoundEvent(type: 'Doorbell', confidence: 0.8));
      expect(store.events, hasLength(1));

      // Switch back to user1 — should see the Fire Alarm.
      await store.setUser('user1');
      expect(store.events, hasLength(1));
      expect(store.events.first.type, 'Fire Alarm');
    });

    test('empty userId falls back to anonymous', () async {
      final store = AlertHistoryStore();
      await store.setUser('');
      await store.addEvent(SoundEvent(type: 'Knock', confidence: 0.7));

      // Create a new store with anonymous and verify data persists.
      final store2 = AlertHistoryStore();
      await store2.setUser('');
      expect(store2.events, hasLength(1));
      expect(store2.events.first.type, 'Knock');
    });
  });

  // ── Add events ────────────────────────────────────────────────────

  group('AlertHistoryStore — addEvent', () {
    test('appends events to the list', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      await store.addEvent(SoundEvent(type: 'Siren', confidence: 0.9));
      await store.addEvent(SoundEvent(type: 'Knock', confidence: 0.7));
      expect(store.events, hasLength(2));
    });

    test('trims to maxHistorySize when exceeded', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      // Add more than maxHistorySize events.
      for (int i = 0; i < AlertHistoryStore.maxHistorySize + 10; i++) {
        await store.addEvent(SoundEvent(type: 'Knock', confidence: 0.5 + i * 0.001));
      }
      expect(store.events.length, AlertHistoryStore.maxHistorySize);
    });

    test('oldest events are trimmed first', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      final oldest = SoundEvent(
        type: 'Oldest',
        confidence: 0.5,
        timestamp: DateTime(2020, 1, 1),
      );
      await store.addEvent(oldest);

      // Fill to max.
      for (int i = 0; i < AlertHistoryStore.maxHistorySize; i++) {
        await store.addEvent(SoundEvent(type: 'Filler $i', confidence: 0.6));
      }

      expect(store.events.length, AlertHistoryStore.maxHistorySize);
      // The oldest event should have been trimmed.
      expect(store.events.any((e) => e.type == 'Oldest'), isFalse);
    });
  });

  // ── Dismiss ───────────────────────────────────────────────────────

  group('AlertHistoryStore — dismiss', () {
    test('marks the specified event as dismissed', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      final event = SoundEvent(type: 'Doorbell', confidence: 0.9);
      await store.addEvent(event);
      expect(store.events.first.dismissed, isFalse);

      final result = await store.dismiss(event.id);
      expect(result, isTrue);
      expect(store.events.first.dismissed, isTrue);
    });

    test('returns false for unknown eventId', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      await store.addEvent(SoundEvent(type: 'Knock', confidence: 0.7));
      final result = await store.dismiss('non-existent-id');
      expect(result, isFalse);
    });

    test('dismissed state persists across reloads', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      final event = SoundEvent(type: 'Phone', confidence: 0.8);
      await store.addEvent(event);
      await store.dismiss(event.id);

      // Create a fresh store and reload the same user.
      final store2 = AlertHistoryStore();
      await store2.setUser('u1');
      expect(store2.events, hasLength(1));
      expect(store2.events.first.dismissed, isTrue);
    });
  });

  // ── Clear ─────────────────────────────────────────────────────────

  group('AlertHistoryStore — clear', () {
    test('removes all events from memory and disk', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      await store.addEvent(SoundEvent(type: 'Siren', confidence: 0.9));
      await store.addEvent(SoundEvent(type: 'Knock', confidence: 0.7));
      expect(store.events, hasLength(2));

      await store.clear();
      expect(store.events, isEmpty);

      // Verify disk is also cleared.
      final store2 = AlertHistoryStore();
      await store2.setUser('u1');
      expect(store2.events, isEmpty);
    });
  });

  // ── Persistence round-trip ────────────────────────────────────────

  group('AlertHistoryStore — persistence', () {
    test('events survive a full reload', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      await store.addEvent(SoundEvent(
        type: 'Fire Alarm',
        confidence: 0.95,
        severity: 'critical',
      ));
      await store.addEvent(SoundEvent(
        type: 'Baby Cry',
        confidence: 0.8,
        severity: 'warning',
      ));

      // Fresh store, same user.
      final store2 = AlertHistoryStore();
      await store2.setUser('u1');
      expect(store2.events, hasLength(2));
      expect(store2.events[0].type, 'Fire Alarm');
      expect(store2.events[0].severity, 'critical');
      expect(store2.events[1].type, 'Baby Cry');
    });

    test('preserves id, type, timestamp, confidence, severity, dismissed',
        () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      final ts = DateTime(2025, 6, 15, 10, 30);
      final event = SoundEvent(
        type: 'Glass Break',
        confidence: 0.88,
        severity: 'critical',
        timestamp: ts,
      );
      await store.addEvent(event);
      await store.dismiss(event.id);

      final store2 = AlertHistoryStore();
      await store2.setUser('u1');
      final loaded = store2.events.first;
      expect(loaded.id, event.id);
      expect(loaded.type, 'Glass Break');
      expect(loaded.confidence, 0.88);
      expect(loaded.severity, 'critical');
      expect(loaded.timestamp, ts);
      expect(loaded.dismissed, isTrue);
    });

    test('corrupt JSON is handled gracefully', () async {
      SharedPreferences.setMockInitialValues({
        'alert_history_u1': 'not-valid-json{{{',
      });

      final store = AlertHistoryStore();
      await store.setUser('u1');
      expect(store.events, isEmpty);
      expect(store.isLoaded, isTrue);
    });
  });

  // ── Prune dismissed ───────────────────────────────────────────────

  group('AlertHistoryStore — pruneDismissed', () {
    test('removes dismissed events older than cutoff', () async {
      final store = AlertHistoryStore();
      await store.setUser('u1');

      final old = SoundEvent(
        type: 'Old Knock',
        confidence: 0.7,
        timestamp: DateTime.now().subtract(const Duration(days: 10)),
      );
      final recent = SoundEvent(type: 'Recent Knock', confidence: 0.8);
      await store.addEvent(old);
      await store.addEvent(recent);
      await store.dismiss(old.id);
      await store.dismiss(recent.id);

      final pruned = await store.pruneDismissed(olderThan: const Duration(days: 5));
      expect(pruned, 1); // only the old one
      expect(store.events, hasLength(1));
      expect(store.events.first.type, 'Recent Knock');
    });
  });

  // ── SoundEvent JSON round-trip ────────────────────────────────────

  group('SoundEvent — JSON round-trip', () {
    test('serializes and deserializes correctly', () {
      final event = SoundEvent(
        type: 'Vehicle Horn',
        confidence: 0.92,
        severity: 'warning',
        timestamp: DateTime(2025, 8, 15),
      );
      final json = event.toJson();
      final restored = SoundEvent.fromJson(json);
      expect(restored.id, event.id);
      expect(restored.type, 'Vehicle Horn');
      expect(restored.confidence, 0.92);
      expect(restored.severity, 'warning');
      expect(restored.dismissed, isFalse);
    });
  });
}
