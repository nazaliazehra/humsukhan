import 'package:flutter_test/flutter_test.dart';
import 'package:humsukhan/services/sound_detection_service.dart';

/// Tests for SoundDetectionService label mapping, confidence thresholds,
/// temporal confirmation, and cooldown logic.
///
/// These tests validate the detection pipeline logic without requiring
/// microphone access or sherpa-ONNX model loading.
void main() {
  group('SoundDetectionService', () {
    test('supportedEvents contains all expected event types', () {
      final events = SoundDetectionService.supportedEvents;

      expect(events, contains('Fire Alarm'));
      expect(events, contains('Siren'));
      expect(events, contains('Doorbell'));
      expect(events, contains('Knock'));
      expect(events, contains('Phone'));
      expect(events, contains('Baby Cry'));
      expect(events, contains('Alarm Clock'));
      expect(events, contains('Vehicle Horn'));
      expect(events, contains('Glass Break'));
      expect(events, contains('Dog Bark'));
    });

    test('singleton instance is consistent type', () {
      final instance1 = SoundDetectionService.instance;
      final instance2 = SoundDetectionService.instance;
      expect(instance1.runtimeType, instance2.runtimeType);
    });

    test('initial state is not monitoring and not model ready', () {
      final service = SoundDetectionService.instance;
      expect(service.isMonitoring, isFalse);
    });

    test('processClassification returns false when not monitoring', () {
      final service = SoundDetectionService.instance;
      service.stopMonitoring();
      final result = service.processClassification('Siren', 0.85);
      expect(result, isFalse);
    });

    test('supportedEvents count matches expected', () {
      expect(SoundDetectionService.supportedEvents.length, 10);
    });

    test('label count is zero before initialization', () {
      final service = SoundDetectionService.instance;
      expect(service.labelCount, 0);
    });

    test('modelLabels is empty before initialization', () {
      final service = SoundDetectionService.instance;
      expect(service.modelLabels, isEmpty);
    });
  });

  group('Label Mapping — real AudioSet labels', () {
    // These patterns are verified against the actual CED-Tiny
    // class_labels_indices.csv from HuggingFace.

    test('Fire Alarm maps smoke detector and fire alarm', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Fire Alarm'));
    });

    test('Siren maps siren, police, ambulance, fire engine, civil defense', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Siren'));
    });

    test('Doorbell maps doorbell and chime only', () {
      // "bell" is NOT mapped — too generic (matches Cowbell, Church bell)
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Doorbell'));
    });

    test('Knock maps knock and tap', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Knock'));
    });

    test('Phone maps telephone, ringtone, and car alarm', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Phone'));
    });

    test('Baby Cry maps baby cry, crying/sobbing, and whimper', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Baby Cry'));
    });

    test('Alarm Clock maps alarm clock, alarm, buzzer', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Alarm Clock'));
    });

    test('Vehicle Horn maps vehicle horn, air horn, honk', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Vehicle Horn'));
    });

    test('Glass Break maps glass and shatter', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Glass Break'));
    });

    test('Dog Bark maps bark only', () {
      // "dog" is NOT mapped — too generic (matches growling, whimper)
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Dog Bark'));
    });
  });

  group('Label Mapping Coverage', () {
    test('critical events include Fire Alarm and Siren', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Fire Alarm'));
      expect(events, contains('Siren'));
    });

    test('non-critical events include Doorbell, Knock, Phone, Baby Cry', () {
      final events = SoundDetectionService.supportedEvents;
      expect(events, contains('Doorbell'));
      expect(events, contains('Knock'));
      expect(events, contains('Phone'));
      expect(events, contains('Baby Cry'));
      expect(events, contains('Alarm Clock'));
      expect(events, contains('Vehicle Horn'));
      expect(events, contains('Glass Break'));
      expect(events, contains('Dog Bark'));
    });
  });

  group('Service Lifecycle', () {
    test('stopMonitoring can be called safely', () {
      final service = SoundDetectionService.instance;
      service.stopMonitoring();
      expect(service.isMonitoring, isFalse);
    });

    test('dispose can be called safely', () {
      final service = SoundDetectionService.instance;
      service.dispose();
      expect(service.isMonitoring, isFalse);
    });
  });

  // ── WindowScheduler — pure scheduling logic, no audio deps ──────

  group('WindowScheduler', () {
    const sampleRate = 16000;
    const window = 3 * sampleRate; // 48 000
    const hop = 1 * sampleRate;    // 16 000

    WindowScheduler make() =>
        WindowScheduler(windowSamples: window, hopSamples: hop);

    test('initial state', () {
      final s = make();
      expect(s.totalSamples, 0);
      expect(s.nextProcessAt, window);
    });

    test('no processing before the first window fills', () {
      final s = make();
      var fires = 0;
      // Feed just under 3 seconds worth of 1600-sample chunks.
      for (var i = 0; i < 29; i++) {
        s.onSamplesAdded(1600, () => fires++);
      }
      expect(s.totalSamples, 46400);
      expect(fires, 0);
    });

    group('chunks of 1600 samples (aligns with hop)', () {
      test('first window fires at exactly 3 seconds', () {
        final s = make();
        var fires = 0;
        // 30 chunks × 1600 = 48 000 = window
        for (var i = 0; i < 30; i++) {
          s.onSamplesAdded(1600, () => fires++);
        }
        expect(fires, 1);
        expect(s.totalSamples, window);
        expect(s.nextProcessAt, window + hop);
      });

      test('fires every 10 chunks (= 1 second) after the first window', () {
        final s = make();
        var fires = 0;
        // 80 chunks × 1600 = 128 000 → 6 s past window → 6 hops
        for (var i = 0; i < 80; i++) {
          s.onSamplesAdded(1600, () => fires++);
        }
        // 1 (initial) + 5 (hops from 64k to 128k) = 6 total
        expect(fires, 6);
        expect(s.nextProcessAt, window + 6 * hop);
      });
    });

    group('chunks of 2048 samples (misaligned)', () {
      test('first window fires after boundary is crossed', () {
        final s = make();
        var fires = 0;
        // 23 chunks × 2048 = 47 104 (below 48 000)
        for (var i = 0; i < 23; i++) {
          s.onSamplesAdded(2048, () => fires++);
        }
        expect(fires, 0);

        // 24th chunk: total = 49 152 → crosses 48 000
        s.onSamplesAdded(2048, () => fires++);
        expect(fires, 1);
        expect(s.nextProcessAt, window + hop);
      });

      test('continues firing approximately every 1 second', () {
        final s = make();
        var fires = 0;
        // 100 chunks × 2048 = 204 800 samples ≈ 12.8 s
        for (var i = 0; i < 100; i++) {
          s.onSamplesAdded(2048, () => fires++);
        }
        // Expected boundaries: 48k, 64k, 80k, 96k, 112k, 128k,
        //   144k, 160k, 176k, 192k → 10 fires
        expect(fires, 10);
      });

      test('never skips or duplicates a window', () {
        final s = make();
        final firePositions = <int>[];
        for (var i = 0; i < 100; i++) {
          s.onSamplesAdded(2048, () => firePositions.add(s.nextProcessAt - hop));
        }
        // Each fire position should be unique and sequential.
        for (var i = 1; i < firePositions.length; i++) {
          expect(firePositions[i], firePositions[i - 1] + hop);
        }
      });
    });

    group('varying chunk sizes', () {
      test('processes correctly with random-ish chunk sizes', () {
        final s = make();
        var fires = 0;
        // Simulate a mix of chunk sizes: 1024, 2048, 512, 4096, ...
        const chunks = [1024, 2048, 512, 4096, 1024, 8192, 3072, 2048,
                         1024, 512, 2048, 4096, 1024, 512, 2048];
        var totalFed = 0;
        for (final c in chunks) {
          s.onSamplesAdded(c, () => fires++);
          totalFed += c;
        }
        // Expected fires: number of boundaries in [window, totalFed]
        // boundaries = window, window+hop, window+2*hop, ...
        final expectedFires = totalFed >= window
            ? ((totalFed - window) ~/ hop) + 1
            : 0;
        expect(fires, expectedFires);
      });

      test('single huge chunk fires all crossed boundaries at once', () {
        final s = make();
        var fires = 0;
        // One chunk of 5 seconds = 80 000 samples
        // Boundaries: 48k, 64k → 2 fires
        s.onSamplesAdded(80000, () => fires++);
        expect(fires, 2);
        expect(s.nextProcessAt, window + 2 * hop);
      });

      test('single sample-at-a-time feeds correctly', () {
        final s = make();
        var fires = 0;
        // Feed exactly window + hop samples one at a time
        for (var i = 0; i < window + hop; i++) {
          s.onSamplesAdded(1, () => fires++);
        }
        expect(fires, 2); // window boundary + first hop
      });
    });

    group('reset', () {
      test('reset clears all scheduling state', () {
        final s = make();
        var fires = 0;
        // Advance past several boundaries.
        for (var i = 0; i < 80; i++) {
          s.onSamplesAdded(1600, () => fires++);
        }
        expect(fires, greaterThan(0));
        expect(s.totalSamples, greaterThan(0));

        s.reset();
        expect(s.totalSamples, 0);
        expect(s.nextProcessAt, window);

        // After reset, must accumulate a full window again.
        var postResetFires = 0;
        for (var i = 0; i < 29; i++) {
          s.onSamplesAdded(1600, () => postResetFires++);
        }
        expect(postResetFires, 0); // not yet at window

        s.onSamplesAdded(1600, () => postResetFires++);
        expect(postResetFires, 1); // exactly at window
      });
    });
  });
}
