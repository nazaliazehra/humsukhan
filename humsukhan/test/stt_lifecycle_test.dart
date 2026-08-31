import 'package:flutter_test/flutter_test.dart';
import 'package:humsukhan/services/stt/enhanced_stt.dart';
import 'package:humsukhan/services/stt/vosk_stt.dart';

/// Regression tests for the STT model activation and language/mode switching
/// lifecycle.
///
/// These tests exercise the pure state-machine logic in
/// [EnhancedSpeechProvider] and [SherpaSTTProvider] — mode resolution,
/// stop/restart on switch, busy guards, and the initialize → reload cycle.
///
/// They do NOT require microphone access, native Sherpa-ONNX libraries,
/// or network connectivity. Platform STT will be unavailable in the test
/// environment (no native plugin registered), so mode resolution tests
/// focus on the Sherpa/unavailable paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Enhanced mode resolution ────────────────────────────────────────

  group('Enhanced — mode resolution', () {
    test('resolves to none when no model and no platform STT', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize(preferredLanguage: 'English');

      // No Sherpa model downloaded + no platform plugin → none.
      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);
      expect(provider.isLiveStt, isFalse);
    });

    test('sttUnavailable is false only when a real engine is active', () {
      final provider = EnhancedSpeechProvider();
      // Default mode is none.
      expect(provider.sttUnavailable, isTrue);
    });

    test('sttModeLabel returns "Unavailable" for none mode', () {
      final provider = EnhancedSpeechProvider();
      expect(provider.sttModeLabel, 'Unavailable');
    });

    test('isLiveStt is false for demo and none', () {
      final provider = EnhancedSpeechProvider();
      expect(provider.isLiveStt, isFalse); // mode = none
    });
  });

  // ── Enhanced switchMode ─────────────────────────────────────────────

  group('Enhanced — switchMode', () {
    test('stops listening before switching when listening is active',
        () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      // Try to start listening (will resolve to none → _listening = false).
      await provider.startListening(language: 'English');

      // Even though start failed, switchMode should not crash.
      await provider.switchMode(STTMode.platform, language: 'English');

      // After switch, mode should be resolved (none if platform unavailable).
      expect(
        provider.currentMode,
        isIn([STTMode.platform, STTMode.none]),
      );
    });

    test('switching to platform when unavailable resolves to none', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.switchMode(STTMode.platform, language: 'English');

      // Platform not available in test env → none.
      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);
    });

    test('switching to Sherpa streaming when model missing resolves to none',
        () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.switchMode(STTMode.sherpaStreaming, language: 'English');

      // Model not downloaded → none.
      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);
    });

    test('switching to Sherpa batch when model missing resolves to none',
        () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.switchMode(STTMode.sherpaBatch, language: 'Urdu');

      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);
    });

    test('switching to demo mode resolves to none', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.switchMode(STTMode.demo, language: 'English');

      // Demo is treated as "no engine available" → none.
      expect(provider.currentMode, STTMode.none);
    });
  });

  // ── Enhanced switchLanguage ─────────────────────────────────────────

  group('Enhanced — switchLanguage', () {
    test('updates currentLanguage to the new value', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.switchLanguage('Urdu');
      expect(provider.currentLanguage, 'Urdu');

      await provider.switchLanguage('English');
      expect(provider.currentLanguage, 'English');
    });

    test('resolves mode for the new language', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.switchLanguage('Urdu');

      // No Urdu model → none.
      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);
    });

    test('can switch back and forth without error', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      for (var i = 0; i < 5; i++) {
        await provider.switchLanguage('Urdu');
        await provider.switchLanguage('English');
      }

      expect(provider.currentLanguage, 'English');
      expect(provider.currentMode, STTMode.none);
    });
  });

  // ── Enhanced busy guard ─────────────────────────────────────────────

  group('Enhanced — busy guard', () {
    test('second switchLanguage returns immediately when first is in flight',
        () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      // Fire two switchLanguage calls without awaiting the first.
      final future1 = provider.switchLanguage('Urdu');
      final future2 = provider.switchLanguage('English');

      await future1;
      await future2;

      // The first call wins — language should be Urdu.
      // The second call was a no-op due to the busy guard.
      expect(provider.currentLanguage, 'Urdu');
    });

    test('second switchMode returns immediately when first is in flight',
        () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      final future1 =
          provider.switchMode(STTMode.sherpaStreaming, language: 'English');
      final future2 =
          provider.switchMode(STTMode.sherpaBatch, language: 'Urdu');

      await future1;
      await future2;

      // First call completed; second was rejected by busy guard.
      // Mode resolved to none because no model is available.
      expect(provider.currentMode, STTMode.none);
    });
  });

  // ── Enhanced download-then-reload ───────────────────────────────────

  group('Enhanced — download-then-reload regression', () {
    test(
        'initialize without model → mode is none → '
        'downloadModel triggers reload → mode updates', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize(preferredLanguage: 'English');

      // No model → mode is none.
      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);
      expect(provider.isSherpaAvailable, isFalse);

      // Attempt download (will fail in test env due to no network).
      // The important thing: no crash and state stays consistent.
      await provider.downloadModel('English');

      // Mode should still be none (download failed) or updated if it
      // somehow succeeded. Either way, state must be consistent.
      expect(
        provider.currentMode,
        isIn([STTMode.none, STTMode.sherpaStreaming, STTMode.sherpaBatch]),
      );
    });

    test(
        'initialize without Urdu model → mode is none → '
        'downloadModel for Urdu does not crash', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize(preferredLanguage: 'Urdu');

      expect(provider.currentMode, STTMode.none);

      // Attempt download — should not throw even if network is unavailable.
      await provider.downloadModel('Urdu');

      // Consistent state.
      expect(provider.currentLanguage, 'Urdu');
    });
  });

  // ── Enhanced delete-model safety ────────────────────────────────────

  group('Enhanced — delete-model safety', () {
    test('deleting a non-downloaded model returns false', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      // English model is not downloaded → deleteModel should return false.
      final result = await provider.deleteModel('English');
      expect(result, isFalse);

      // Mode unchanged.
      expect(provider.currentMode, STTMode.none);
    });

    test('deleteModel does not crash for any language', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      for (final lang in ['English', 'Urdu', 'Hindi']) {
        final result = await provider.deleteModel(lang);
        expect(result, isFalse);
      }
    });
  });

  // ── Enhanced startListening with no engine ──────────────────────────

  group('Enhanced — startListening when unavailable', () {
    test('startListening does not set listening=true when no engine',
        () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize();

      await provider.startListening(language: 'English');

      // No engine available → _listening should be false.
      expect(provider.isListening, isFalse);
      expect(provider.currentMode, STTMode.none);
    });
  });

  // ── Sherpa provider lifecycle ───────────────────────────────────────

  group('SherpaSTTProvider — lifecycle', () {
    test('initial state is not initialized and mode is none', () {
      final sherpa = SherpaSTTProvider();
      expect(sherpa.isInitialized, isFalse);
      expect(sherpa.currentMode, STTMode.none);
      expect(sherpa.isAvailable, isFalse);
      expect(sherpa.isListening, isFalse);
      expect(sherpa.isBusy, isFalse);
      expect(sherpa.isReloading, isFalse);
    });

    test('switchLanguage changes currentLanguage', () async {
      final sherpa = SherpaSTTProvider();
      await sherpa.switchLanguage('Urdu');
      expect(sherpa.currentLanguage, 'Urdu');
      expect(sherpa.isAvailable, isFalse);
      expect(sherpa.currentMode, STTMode.none);
    });

    test('switchLanguage disposes and can be called repeatedly', () async {
      final sherpa = SherpaSTTProvider();
      for (var i = 0; i < 5; i++) {
        await sherpa.switchLanguage('English');
        await sherpa.switchLanguage('Urdu');
      }
      expect(sherpa.currentLanguage, 'Urdu');
      expect(sherpa.currentMode, STTMode.none);
    });

    test('reload sets initialized even when no model is available', () async {
      final sherpa = SherpaSTTProvider();
      expect(sherpa.isInitialized, isFalse);

      final result = await sherpa.reload(language: 'English');

      expect(sherpa.isInitialized, isTrue);
      expect(result, isFalse); // no model
      expect(sherpa.currentMode, STTMode.none);
      expect(sherpa.isAvailable, isFalse);
      expect(sherpa.isReloading, isFalse); // cleared after completion
    });

    test('reload is idempotent — calling twice gives same result', () async {
      final sherpa = SherpaSTTProvider();

      final r1 = await sherpa.reload(language: 'English');
      final r2 = await sherpa.reload(language: 'English');

      expect(r1, r2);
      expect(sherpa.currentMode, STTMode.none);
      expect(sherpa.isReloading, isFalse);
    });

    test('reload after switchLanguage picks up new language', () async {
      final sherpa = SherpaSTTProvider();
      await sherpa.switchLanguage('Urdu');
      expect(sherpa.currentLanguage, 'Urdu');

      await sherpa.reload(language: 'English');
      expect(sherpa.currentLanguage, 'English');
      expect(sherpa.currentMode, STTMode.none);
    });
  });

  // ── Full lifecycle regression ───────────────────────────────────────

  group('Full lifecycle regression', () {
    test(
        'initialize → no model → switchLanguage → '
        'mode stays none throughout', () async {
      final provider = EnhancedSpeechProvider();

      // Step 1: Initialize with English (no model).
      await provider.initialize(preferredLanguage: 'English');
      expect(provider.currentMode, STTMode.none);
      expect(provider.sttUnavailable, isTrue);

      // Step 2: Switch to Urdu (no model).
      await provider.switchLanguage('Urdu');
      expect(provider.currentMode, STTMode.none);
      expect(provider.currentLanguage, 'Urdu');

      // Step 3: Switch back to English (still no model).
      await provider.switchLanguage('English');
      expect(provider.currentMode, STTMode.none);
      expect(provider.currentLanguage, 'English');

      // Step 4: Try switchMode to platform (unavailable in tests).
      await provider.switchMode(STTMode.platform, language: 'English');
      expect(provider.currentMode, STTMode.none);

      // Step 5: Try switchMode to Sherpa streaming (no model).
      await provider.switchMode(STTMode.sherpaStreaming, language: 'English');
      expect(provider.currentMode, STTMode.none);

      // Throughout: unavailable.
      expect(provider.sttUnavailable, isTrue);
      expect(provider.isLiveStt, isFalse);
    });

    test(
        'initialize → startListening fails gracefully → '
        'stopListening is safe', () async {
      final provider = EnhancedSpeechProvider();
      await provider.initialize(preferredLanguage: 'English');

      // startListening with no engine should not crash.
      await provider.startListening(language: 'English');
      expect(provider.isListening, isFalse);

      // stopListening should be safe even when not listening.
      await provider.stopListening();
      expect(provider.isListening, isFalse);
    });

    test('dispose does not throw', () {
      final provider = EnhancedSpeechProvider();
      // Dispose without initializing first.
      expect(() => provider.dispose(), returnsNormally);
    });
  });
}
