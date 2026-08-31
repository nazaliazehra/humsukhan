import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'vosk_stt.dart';
import 'model_manager.dart';

// Re-export STTMode and related types from vosk_stt.dart
export 'vosk_stt.dart' show STTMode;

/// Enhanced Speech-to-Text provider with hybrid offline/online architecture.
///
/// Priority order:
/// 1. Sherpa-ONNX Streaming (English) - Real-time captions, offline
/// 2. Sherpa-ONNX Batch (Urdu/Hindi) - Short delay, offline
/// 3. Platform STT (Google/Apple) - Requires internet
/// 4. Demo mode - Fake phrases for testing
///
/// The provider automatically selects the best available mode based on:
/// - Which models are downloaded
/// - The selected language
/// - Network availability
class EnhancedSpeechProvider {
  final SpeechToText _platformSTT = SpeechToText();
  final SherpaSTTProvider _sherpaSTT = SherpaSTTProvider();
  final StreamController<SpeechResultEvent> _controller =
      StreamController<SpeechResultEvent>.broadcast();

  final ModelManager _modelManager = ModelManager.instance;

  bool _initialized = false;
  bool _listening = false;
  bool _busy = false;
  bool _platformAvailable = false;
  bool _sherpaAvailable = false;
  STTMode _currentMode = STTMode.none;
  String _currentLanguage = 'English';
  StreamSubscription<SherpaSTTResult>? _sherpaSubscription;

  Function(double progress, String status)? onModelDownloadProgress;

  Stream<SpeechResultEvent> get onResult => _controller.stream;
  bool get isListening => _listening;
  bool get isAvailable => _platformAvailable || _sherpaAvailable;
  STTMode get currentMode => _currentMode;
  String get currentLanguage => _currentLanguage;
  bool get isSherpaAvailable => _sherpaAvailable;
  bool get isPlatformAvailable => _platformAvailable;

  // Convenience getters for UI
  bool get isOfflineMode => _currentMode == STTMode.sherpaStreaming || _currentMode == STTMode.sherpaBatch;
  bool get isStreamingMode => _currentMode == STTMode.sherpaStreaming;
  bool get isBatchMode => _currentMode == STTMode.sherpaBatch;
  bool get isOnlineMode => _currentMode == STTMode.platform;
  bool get isDemoMode => _currentMode == STTMode.demo;
  bool get isBusy => _busy;

  /// True when no STT engine is available (neither Sherpa nor platform).
  bool get sttUnavailable =>
      _currentMode == STTMode.none || _currentMode == STTMode.demo;

  /// Initialize both STT engines.
  Future<bool> initialize({String preferredLanguage = 'English'}) async {
    if (_initialized) return isAvailable;

    _currentLanguage = preferredLanguage;

    // Initialize model manager
    await _modelManager.initialize();

    // Try Sherpa-ONNX offline STT first (primary)
    try {
      _sherpaAvailable = await _sherpaSTT.initialize(language: preferredLanguage);
      debugPrint('Sherpa STT available: $_sherpaAvailable');
    } catch (e) {
      debugPrint('Sherpa STT init failed: $e');
      _sherpaAvailable = false;
    }

    // Try platform STT as fallback (requires internet on Android)
    try {
      _platformAvailable = await _platformSTT.initialize(
        onStatus: _onPlatformStatus,
        onError: (error) {
          debugPrint('Platform STT error: ${error.errorMsg}');
          if (_listening && (error.errorMsg == 'no_match' || error.errorMsg == 'speech_timeout')) {
            _platformSTT.listen();
          }
        },
      );
      debugPrint('Platform STT available: $_platformAvailable');
    } catch (e) {
      debugPrint('Platform STT init failed: $e');
      _platformAvailable = false;
    }

    _initialized = true;

    // Set initial mode based on what's available
    _currentMode = _resolveMode(preferredLanguage);

    debugPrint('STT initialized - Mode: $_currentMode, Language: $_currentLanguage');
    return isAvailable;
  }

  /// Resolve the best STT mode for a given language.
  ///
  /// Returns `STTMode.none` when no engine is available — never silently
  /// falls into demo mode.
  STTMode _resolveMode(String language) {
    if (_sherpaAvailable && _modelManager.isModelReady(language)) {
      final model = _modelManager.getBestModel(language);
      if (model != null && model.isStreaming) {
        return STTMode.sherpaStreaming;
      }
      return STTMode.sherpaBatch;
    }
    if (_platformAvailable) return STTMode.platform;
    return STTMode.none;
  }

  void _onPlatformStatus(String status) {
    debugPrint('Platform STT status: $status');
    if (status == 'notListening' && _listening) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (_listening && _currentMode == STTMode.platform) {
          _platformSTT.listen();
        }
      });
    }
  }

  /// Start listening with the best available engine for the current language.
  Future<void> startListening({String language = 'English'}) async {
    if (!_initialized) {
      await initialize(preferredLanguage: language);
    }

    _currentLanguage = language;

    // Resolve mode for the selected language
    _currentMode = _resolveMode(language);

    if (_currentMode == STTMode.none) {
      // No engine available — cannot listen.
      _listening = false;
      debugPrint('Cannot start listening: no STT engine available for $language');
      return;
    }

    _listening = true;

    switch (_currentMode) {
      case STTMode.sherpaStreaming:
        await _startSherpaStreaming(language);
        break;
      case STTMode.sherpaBatch:
        await _startSherpaBatch(language);
        break;
      case STTMode.platform:
        await _startPlatformListening(language);
        break;
      default:
        break;
    }

    debugPrint('Started listening in $_currentMode mode for $language');
  }

  /// Start Sherpa streaming mode (real-time English captions).
  Future<void> _startSherpaStreaming(String language) async {
    // Cancel any previous Sherpa subscription to prevent listener leak
    _sherpaSubscription?.cancel();

    _sherpaSubscription = _sherpaSTT.onResult.listen((result) {
      _controller.add(SpeechResultEvent(
        text: result.text,
        isFinal: result.isFinal,
        confidence: result.confidence,
        language: _detectLanguage(result.text),
        isLive: true,
        mode: STTMode.sherpaStreaming,
      ));
    });

    await _sherpaSTT.startListening(language: language);
  }

  /// Start Sherpa batch mode (Urdu/Hindi with short delay).
  Future<void> _startSherpaBatch(String language) async {
    // Cancel any previous Sherpa subscription to prevent listener leak
    _sherpaSubscription?.cancel();

    _sherpaSubscription = _sherpaSTT.onResult.listen((result) {
      _controller.add(SpeechResultEvent(
        text: result.text,
        isFinal: result.isFinal,
        confidence: result.confidence,
        language: _detectLanguage(result.text),
        isLive: true,
        mode: STTMode.sherpaBatch,
      ));
    });

    await _sherpaSTT.startListening(language: language);
  }

  /// Start platform-native STT (requires internet on Android).
  Future<void> _startPlatformListening(String language) async {
    _platformSTT.listen(
      onResult: _onPlatformResult,
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 5),
        localeId: _getLocaleId(language),
        cancelOnError: false,
        partialResults: true,
      ),
    );
  }

  void _onPlatformResult(SpeechRecognitionResult result) {
    _controller.add(SpeechResultEvent(
      text: result.recognizedWords,
      isFinal: result.finalResult,
      confidence: result.confidence,
      language: _detectLanguage(result.recognizedWords),
      isLive: true,
      mode: STTMode.platform,
    ));
  }

  void _startDemoMode() {
    // No-op: demo/simulated mode is disabled.
    // Speech recognition requires either:
    // 1. A downloaded Sherpa-ONNX model (offline)
    // 2. Platform STT (requires internet)
    // The UI should show 'Unavailable' when neither is available.
    debugPrint('Demo mode disabled. No simulated captions will be generated.');
  }

  /// Stop listening.
  ///
  /// Always stops every engine (Sherpa + platform) defensively so the
  /// microphone is released regardless of which mode was active.
  Future<void> stopListening() async {
    _listening = false;
    _sherpaSubscription?.cancel();
    _sherpaSubscription = null;

    try {
      await _sherpaSTT.stopListening();
    } catch (_) {}
    try {
      await _platformSTT.stop();
    } catch (_) {}
  }

  /// Switch STT mode manually.
  ///
  /// Captures the current listening state, stops safely, changes the mode
  /// (reloading Sherpa when switching to a Sherpa mode), and restarts
  /// automatically if the user was listening before the switch.
  ///
  /// If the requested model is unavailable, exposes [sttUnavailable] instead
  /// of silently falling into demo mode.
  Future<void> switchMode(STTMode mode, {String language = 'English'}) async {
    if (_busy) return;
    _busy = true;
    try {
      final wasListening = _listening;
      if (_listening) await stopListening();

      _currentLanguage = language;

      // Sherpa modes require the correct recognizer to be loaded.
      if (mode == STTMode.sherpaStreaming || mode == STTMode.sherpaBatch) {
        _sherpaAvailable = await _sherpaSTT.reload(language: language);
        final resolved = _resolveMode(language);
        _currentMode =
            (resolved == STTMode.sherpaStreaming || resolved == STTMode.sherpaBatch)
                ? resolved
                : STTMode.none;
      } else if (mode == STTMode.platform) {
        _currentMode = _platformAvailable ? STTMode.platform : STTMode.none;
      } else {
        // demo / none — no engine available
        _currentMode = STTMode.none;
      }

      if (wasListening && _currentMode != STTMode.none) {
        _listening = true;
        switch (_currentMode) {
          case STTMode.sherpaStreaming:
            await _startSherpaStreaming(language);
            break;
          case STTMode.sherpaBatch:
            await _startSherpaBatch(language);
            break;
          case STTMode.platform:
            await _startPlatformListening(language);
            break;
          default:
            break;
        }
      }
    } finally {
      _busy = false;
    }
  }

  /// Switch to a different language.
  ///
  /// Captures the listening state, stops safely, reloads Sherpa with the new
  /// language, resolves the best available mode, and restarts automatically
  /// if the user was listening before the switch.
  Future<void> switchLanguage(String language) async {
    if (_busy) return;
    _busy = true;
    try {
      final wasListening = _listening;
      if (_listening) await stopListening();

      _currentLanguage = language;

      // Reload Sherpa with the new language (handles disposal internally).
      _sherpaAvailable = await _sherpaSTT.switchLanguage(language);

      // Resolve the best available mode for the new language.
      _currentMode = _resolveMode(language);

      // Restart automatically if the user was listening before the switch.
      if (wasListening && _currentMode != STTMode.none) {
        _listening = true;
        switch (_currentMode) {
          case STTMode.sherpaStreaming:
            await _startSherpaStreaming(language);
            break;
          case STTMode.sherpaBatch:
            await _startSherpaBatch(language);
            break;
          case STTMode.platform:
            await _startPlatformListening(language);
            break;
          default:
            break;
        }
      }
    } finally {
      _busy = false;
    }
  }

  /// Download a Sherpa-ONNX model for offline use.
  ///
  /// After a successful download, reloads the Sherpa engine so the new model
  /// is activated immediately without requiring an app restart.
  Future<bool> downloadModel(String language) async {
    final success = await _modelManager.downloadModel(language);
    if (success) {
      _sherpaAvailable = await _sherpaSTT.reload(language: language);
      _currentMode = _resolveMode(language);
    }
    return success;
  }

  /// Check if a model is downloaded for a language.
  bool isModelReady(String language) {
    return _modelManager.isModelReady(language);
  }

  /// Get model status for a language.
  ModelStatus? getModelStatus(String language) {
    return _modelManager.statuses[language];
  }

  /// Get all available languages.
  List<String> get offlineLanguages => ModelManager.availableModels.keys.toList();

  /// Get all languages with downloaded models.
  List<String> get readyLanguages => _modelManager.readyLanguages;

  /// Get the best mode label for UI display.
  String get sttModeLabel {
    switch (_currentMode) {
      case STTMode.sherpaStreaming:
        return 'Offline (Live)';
      case STTMode.sherpaBatch:
        return 'Offline (Batch)';
      case STTMode.platform:
        return 'Online';
      case STTMode.demo:
        return 'Demo Mode';
      case STTMode.none:
        return 'Unavailable';
    }
  }

  String _getLocaleId(String language) {
    switch (language.toLowerCase()) {
      case 'english':
        return 'en-US';
      case 'roman urdu':
      case 'urdu':
        return 'ur-PK';
      default:
        return 'en-US';
    }
  }

  String _detectLanguage(String text) {
    final urduScript = RegExp(r'[\u0600-\u06FF]');
    final romanUrduWords = ['kya', 'hai', 'mein', 'tum', 'aap', 'ho', 'se', 'ko'];
    if (urduScript.hasMatch(text)) return 'Urdu';
    if (romanUrduWords.any((w) => text.toLowerCase().contains(w))) return 'Roman Urdu';
    return 'English';
  }

  void dispose() {
    _sherpaSubscription?.cancel();
    _platformSTT.cancel();
    _sherpaSTT.dispose();
    _controller.close();
    _modelManager.dispose();
  }
}

/// Speech result event with mode information.
class SpeechResultEvent {
  final String text;
  final bool isFinal;
  final double confidence;
  final String language;
  final bool isLive;
  final STTMode mode;

  const SpeechResultEvent({
    required this.text,
    this.isFinal = false,
    this.confidence = 0.0,
    this.language = 'English',
    this.isLive = true,
    this.mode = STTMode.platform,
  });

  bool get isOffline => mode == STTMode.sherpaStreaming || mode == STTMode.sherpaBatch;
  bool get isStreaming => mode == STTMode.sherpaStreaming;
  bool get isBatch => mode == STTMode.sherpaBatch;
  bool get isOnline => mode == STTMode.platform;
}
