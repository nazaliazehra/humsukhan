import 'package:flutter_test/flutter_test.dart';
import 'package:humsukhan/models/models.dart';

/// Tests for [AlertPolicy] — the single normalized source of truth for
/// how detected environmental events should be presented to the user.
///
/// These tests are pure Dart (no platform channels, no native deps).
void main() {
  // ── AlertPolicy construction ──────────────────────────────────────

  group('AlertPolicy — construction', () {
    test('default values', () {
      const policy = AlertPolicy();
      expect(policy.haptic, isTrue);
      expect(policy.visual, isTrue);
      expect(policy.screenFlash, isTrue);
      expect(policy.flashlight, isFalse);
      expect(policy.allowedAlerts, isEmpty);
    });

    test('custom values', () {
      final policy = AlertPolicy(
        haptic: false,
        visual: true,
        screenFlash: false,
        flashlight: true,
        allowedAlerts: {'Fire Alarm', 'Siren'},
      );
      expect(policy.haptic, isFalse);
      expect(policy.visual, isTrue);
      expect(policy.screenFlash, isFalse);
      expect(policy.flashlight, isTrue);
      expect(policy.allowedAlerts, hasLength(2));
    });
  });

  // ── AlertPolicy.isAllowed ─────────────────────────────────────────

  group('AlertPolicy — isAllowed', () {
    final policy = AlertPolicy(
      allowedAlerts: {'Fire Alarm', 'Siren', 'Doorbell'},
    );

    test('returns true for allowed event types', () {
      expect(policy.isAllowed('Fire Alarm'), isTrue);
      expect(policy.isAllowed('Siren'), isTrue);
      expect(policy.isAllowed('Doorbell'), isTrue);
    });

    test('returns false for disallowed event types', () {
      expect(policy.isAllowed('Knock'), isFalse);
      expect(policy.isAllowed('Phone'), isFalse);
      expect(policy.isAllowed('Baby Cry'), isFalse);
      expect(policy.isAllowed('Dog Bark'), isFalse);
    });

    test('returns false for empty allowed set', () {
      const empty = AlertPolicy();
      expect(empty.isAllowed('Fire Alarm'), isFalse);
      expect(empty.isAllowed('Siren'), isFalse);
    });

    test('empty string is not allowed unless explicitly added', () {
      expect(policy.isAllowed(''), isFalse);
    });
  });

  // ── AlertPolicy.isSilent ──────────────────────────────────────────

  group('AlertPolicy — isSilent', () {
    test('true when all feedback is disabled', () {
      const policy = AlertPolicy(
        haptic: false,
        visual: false,
        screenFlash: false,
        flashlight: false,
      );
      expect(policy.isSilent, isTrue);
    });

    test('false when any feedback is enabled', () {
      const hapticOnly = AlertPolicy(
        haptic: true,
        visual: false,
        screenFlash: false,
        flashlight: false,
      );
      expect(hapticOnly.isSilent, isFalse);

      const visualOnly = AlertPolicy(
        haptic: false,
        visual: true,
        screenFlash: false,
        flashlight: false,
      );
      expect(visualOnly.isSilent, isFalse);

      const flashOnly = AlertPolicy(
        haptic: false,
        visual: false,
        screenFlash: false,
        flashlight: true,
      );
      expect(flashOnly.isSilent, isFalse);
    });

    test('default policy is not silent', () {
      const policy = AlertPolicy();
      expect(policy.isSilent, isFalse);
    });
  });

  // ── AlertPolicy JSON round-trip ───────────────────────────────────

  group('AlertPolicy — JSON', () {
    test('toJson produces expected keys', () {
      const policy = AlertPolicy(
        haptic: false,
        visual: true,
        screenFlash: false,
        flashlight: true,
        allowedAlerts: {'Siren', 'Fire Alarm'},
      );
      final json = policy.toJson();
      expect(json['haptic'], isFalse);
      expect(json['visual'], isTrue);
      expect(json['screenFlash'], isFalse);
      expect(json['flashlight'], isTrue);
      // Allowed alerts are sorted alphabetically.
      expect(json['allowedAlerts'], ['Fire Alarm', 'Siren']);
    });

    test('fromJson reconstructs the policy', () {
      const original = AlertPolicy(
        haptic: false,
        visual: true,
        screenFlash: false,
        flashlight: true,
        allowedAlerts: {'Fire Alarm', 'Siren', 'Doorbell'},
      );
      final json = original.toJson();
      final restored = AlertPolicy.fromJson(json);

      expect(restored.haptic, original.haptic);
      expect(restored.visual, original.visual);
      expect(restored.screenFlash, original.screenFlash);
      expect(restored.flashlight, original.flashlight);
      expect(restored.allowedAlerts, original.allowedAlerts);
    });

    test('round-trip preserves all fields', () {
      final original = AlertPolicy(
        haptic: true,
        visual: false,
        screenFlash: true,
        flashlight: false,
        allowedAlerts: {'Knock', 'Phone', 'Baby Cry'},
      );
      final restored = AlertPolicy.fromJson(original.toJson());
      expect(restored, equals(original));
    });

    test('fromJson handles missing fields gracefully', () {
      final policy = AlertPolicy.fromJson({});
      // All defaults.
      expect(policy.haptic, isTrue);
      expect(policy.visual, isTrue);
      expect(policy.screenFlash, isTrue);
      expect(policy.flashlight, isFalse);
      expect(policy.allowedAlerts, isEmpty);
    });

    test('fromJson handles partial data', () {
      final policy = AlertPolicy.fromJson({
        'haptic': false,
        'allowedAlerts': ['Siren'],
      });
      expect(policy.haptic, isFalse);
      expect(policy.visual, isTrue); // default
      expect(policy.allowedAlerts, {'Siren'});
    });
  });

  // ── AlertPolicy equality ──────────────────────────────────────────

  group('AlertPolicy — equality', () {
    test('identical policies are equal', () {
      const a = AlertPolicy(haptic: true, flashlight: false);
      const b = AlertPolicy(haptic: true, flashlight: false);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different feedback flags are not equal', () {
      const a = AlertPolicy(haptic: true);
      const b = AlertPolicy(haptic: false);
      expect(a, isNot(equals(b)));
    });

    test('different allowed sets are not equal', () {
      final a = AlertPolicy(allowedAlerts: {'Fire Alarm'});
      final b = AlertPolicy(allowedAlerts: {'Siren'});
      expect(a, isNot(equals(b)));
    });

    test('same allowed sets in different order are equal', () {
      final a = AlertPolicy(allowedAlerts: {'Siren', 'Fire Alarm'});
      final b = AlertPolicy(allowedAlerts: {'Fire Alarm', 'Siren'});
      expect(a, equals(b));
    });
  });

  // ── Integration: all supported events ─────────────────────────────

  group('AlertPolicy — supported events coverage', () {
    // These must match SoundDetectionService.supportedEvents exactly.
    const supportedEvents = [
      'Fire Alarm',
      'Siren',
      'Doorbell',
      'Knock',
      'Phone',
      'Baby Cry',
      'Alarm Clock',
      'Vehicle Horn',
      'Glass Break',
      'Dog Bark',
    ];

    test('all supported events can be included in allowedAlerts', () {
      final policy = AlertPolicy(allowedAlerts: supportedEvents.toSet());
      for (final event in supportedEvents) {
        expect(policy.isAllowed(event), isTrue,
            reason: '$event should be allowed');
      }
    });

    test('all supported events can be individually disabled', () {
      for (final event in supportedEvents) {
        final others = supportedEvents.where((e) => e != event).toSet();
        final policy = AlertPolicy(allowedAlerts: others);
        expect(policy.isAllowed(event), isFalse,
            reason: '$event should be disallowed');
        // All others remain allowed.
        for (final other in others) {
          expect(policy.isAllowed(other), isTrue);
        }
      }
    });

    test('10 supported event types', () {
      expect(supportedEvents, hasLength(10));
    });
  });
}
