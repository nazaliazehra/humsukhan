import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../models/models.dart';
import 'audio_model_manager.dart';
import 'sherpa_audio_tagger.dart';

/// Describes the outcome of a monitoring startup attempt.
///
/// Each variant identifies a specific subsystem that failed, so the UI
/// can report a truthful state instead of a generic "Microphone unavailable".
enum StartupResult {
  /// Microphone permission was denied by the user or OS.
  permissionDenied,

  /// Microphone permission is granted but the audio recorder could not be
  /// created or started (hardware issue, another app holding the mic, etc.).
  recorderFailed,

  /// The environmental sound-classification model is not installed locally.
  modelUnavailable,

  /// The sherpa-onnx audio tagger failed to initialise with the model.
  taggerFailed,

  /// An unexpected error occurred during startup.
  unknownError,

  /// Monitoring started successfully.
  success,
}

/// Rolling-window / hop scheduler for audio-stream processing.
///
/// Tracks the next sample position at which a fixed-size window should be
/// processed.  Each call to [onSamplesAdded] reports how many new samples
/// have been appended to the audio buffer; the scheduler fires [onProcess]
/// once for every hop boundary that was crossed, regardless of the incoming
/// chunk size.
///
/// Pure-arithmetic scheduling — no audio or model dependencies — so it can
/// be unit-tested in isolation.
class WindowScheduler {
  /// Window length in samples (e.g. 3 s × 16 kHz = 48 000).
  final int windowSamples;

  /// Hop (stride) length in samples (e.g. 1 s × 16 kHz = 16 000).
  final int hopSamples;

  /// Total samples seen since the last [reset].
  int totalSamples = 0;

  /// Absolute sample index of the next window to process.
  int nextProcessAt;

  WindowScheduler({required this.windowSamples, required this.hopSamples})
      : nextProcessAt = windowSamples;

  /// Reset all counters.  Call on monitoring start / stop.
  void reset() {
    totalSamples = 0;
    nextProcessAt = windowSamples;
  }

  /// Report [count] newly arrived samples.
  ///
  /// Invokes [onProcess] once for every window boundary that the new samples
  /// cross.  With a 3-second window and 1-second hop, the first callback
  /// fires after 48 000 samples and then every 16 000 samples thereafter —
  /// even when incoming chunks do not align to those boundaries.
  void onSamplesAdded(int count, void Function() onProcess) {
    totalSamples += count;
    // Fire for every boundary crossed by the new samples.
    while (nextProcessAt <= totalSamples) {
      onProcess();
      nextProcessAt += hopSamples;
    }
  }
}

class SoundDetectionService {
  SoundDetectionService._();
  static SoundDetectionService? _instance;
  static SoundDetectionService get instance => _instance ??= SoundDetectionService._();

  bool _initialized = false;
  bool _monitoring = false;
  AudioRecorder? _audioRecorder;
  StreamSubscription<Uint8List>? _audioSubscription;
  Function(SoundEvent)? onSoundDetected;
  final SherpaAudioTagger _tagger = SherpaAudioTagger();

  static const int _sampleRate = 16000;
  static const int _windowSamples = 3 * _sampleRate;
  static const int _hopSamples = 1 * _sampleRate;
  static const double _rmsGateThreshold = 200.0;
  static const Duration _cooldownDuration = Duration(seconds: 30);
  static const Duration _temporalWindow = Duration(seconds: 8);

  final Int16List _pcmBuffer = Int16List(_windowSamples);
  final Float32List _windowFloat = Float32List(_windowSamples);
  int _pcmWritePos = 0;
  final WindowScheduler _scheduler = WindowScheduler(
    windowSamples: _windowSamples,
    hopSamples: _hopSamples,
  );
  final Map<String, DateTime> _lastDetectionTime = {};
  final Map<String, List<DateTime>> _temporalBuffer = {};

  static const Map<String, List<String>> _labelMapping = {
    'Fire Alarm': ['smoke detector, smoke alarm', 'fire alarm'],
    'Siren': ['siren', 'police car (siren)', 'ambulance (siren)', 'fire engine, fire truck (siren)', 'civil defense siren', 'emergency vehicle'],
    'Doorbell': ['doorbell', 'chime'],
    'Knock': ['knock', 'tap'],
    'Phone': ['telephone', 'telephone bell ringing', 'ringtone', 'car alarm'],
    'Baby Cry': ['baby cry, infant cry', 'crying, sobbing', 'whimper'],
    'Alarm Clock': ['alarm clock', 'alarm', 'buzzer'],
    'Vehicle Horn': ['vehicle horn, car horn, honking', 'air horn, truck horn', 'honk'],
    'Glass Break': ['glass', 'shatter'],
    'Dog Bark': ['bark'],
  };

  static const Set<String> _criticalEvents = {'Fire Alarm', 'Siren'};
  static const double _criticalThreshold = 0.70;
  static const double _nonCriticalThreshold = 0.55;

  bool get isInitialized => _initialized;
  bool get isMonitoring => _monitoring;
  bool get isModelReady => _tagger.isInitialized;
  int get labelCount => _tagger.labels.length;
  List<String> get modelLabels => _tagger.labels;
  static List<String> get supportedEvents => _labelMapping.keys.toList();

  Future<bool> initialize({bool requestPermission = true}) async {
    if (_initialized) {
      return _audioRecorder != null && await _hasPermission();
    }
    try {
      if (requestPermission) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          debugPrint('SoundDetection: microphone permission denied');
          _initialized = true;
          return false;
        }
      } else if (!await _hasPermission()) {
        debugPrint('SoundDetection: microphone permission unavailable');
        _initialized = true;
        return false;
      }

      final modelReady = await AudioModelManager.instance.initialize();
      if (!modelReady) {
        debugPrint('SoundDetection: local environmental model is unavailable');
        _initialized = true;
        return false;
      }
      _audioRecorder ??= AudioRecorder();
      _initialized = true;
      return true;
    } catch (e) {
      debugPrint('SoundDetection init error: $e');
      _initialized = true;
      return false;
    }
  }

  Future<bool> _hasPermission() async => (await Permission.microphone.status).isGranted;

  /// Start the local environmental monitoring pipeline.
  ///
  /// Returns a [StartupResult] that identifies which subsystem failed
  /// (if any) so the UI can report a truthful status.
  Future<StartupResult> startMonitoring({bool permissionAlreadyGranted = false}) async {
    if (_monitoring) return StartupResult.success;
    if (!_initialized) {
      final ok = await initialize(requestPermission: !permissionAlreadyGranted);
      if (!ok) {
        // Distinguish permission denial from other init failures.
        if (!permissionAlreadyGranted) {
          final status = await Permission.microphone.status;
          if (!status.isGranted) return StartupResult.permissionDenied;
        }
        return StartupResult.unknownError;
      }
    }
    if (_audioRecorder == null) return StartupResult.recorderFailed;

    try {
      if (!permissionAlreadyGranted && !await _audioRecorder!.hasPermission()) {
        debugPrint('SoundDetection: no recorder permission');
        return StartupResult.permissionDenied;
      }
      if (!await AudioModelManager.instance.initialize()) {
        debugPrint('SoundDetection: refusing to start without local model');
        return StartupResult.modelUnavailable;
      }
      if (!await _tagger.initialize()) {
        debugPrint('SoundDetection: tagger initialization failed');
        return StartupResult.taggerFailed;
      }

      const config = RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRate, numChannels: 1);
      final stream = await _audioRecorder!.startStream(config);
      _pcmWritePos = 0;
      _scheduler.reset();
      _clearTemporalBuffer();
      _audioSubscription = stream.listen(_onAudioData,
          onDone: () => debugPrint('SoundDetection: audio stream ended'),
          onError: (e) => debugPrint('SoundDetection: audio stream error: $e'));
      _monitoring = true;
      debugPrint('SoundDetection: local monitoring active');
      return StartupResult.success;
    } catch (e) {
      debugPrint('SoundDetection start error: $e');
      _monitoring = false;
      _tagger.release();
      return StartupResult.unknownError;
    }
  }

  void stopMonitoring() {
    _monitoring = false;
    _audioSubscription?.cancel();
    _audioSubscription = null;
    try { _audioRecorder?.stop(); } catch (_) {}
    try { _audioRecorder?.dispose(); } catch (_) {}
    _audioRecorder = null;
    _tagger.release();
    _pcmWritePos = 0;
    _scheduler.reset();
    debugPrint('SoundDetection: stopped; microphone and model released');
  }

  void _onAudioData(Uint8List data) {
    if (!_monitoring || data.isEmpty || data.lengthInBytes < 2) return;
    final offset = data.offsetInBytes;
    final length = data.lengthInBytes - (data.lengthInBytes % 2);
    final samples = Int16List.view(data.buffer, offset, length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      _pcmBuffer[_pcmWritePos] = samples[i];
      _pcmWritePos = (_pcmWritePos + 1) % _windowSamples;
    }
    _scheduler.onSamplesAdded(samples.length, _processWindow);
  }

  void _processWindow() {
    if (!_tagger.isInitialized) return;
    var sumSq = 0.0;
    final start = (_pcmWritePos - _windowSamples + _windowSamples) % _windowSamples;
    for (var i = 0; i < _windowSamples; i++) {
      final s = _pcmBuffer[(start + i) % _windowSamples].toDouble();
      sumSq += s * s;
    }
    final rmsSq = sumSq / _windowSamples;
    if (rmsSq < _rmsGateThreshold * _rmsGateThreshold) return;

    for (var i = 0; i < _windowSamples; i++) {
      _windowFloat[i] = _pcmBuffer[(start + i) % _windowSamples] / 32768.0;
    }
    final results = _tagger.classify(samples: _windowFloat, topK: 10);
    for (final result in results) {
      _processDetection(result.label, result.probability);
    }
  }

  void _processDetection(String label, double confidence) {
    if (!_monitoring) return;
    final eventType = _mapLabelToEvent(label);
    if (eventType == null) return;
    final threshold = _criticalEvents.contains(eventType) ? _criticalThreshold : _nonCriticalThreshold;
    if (confidence < threshold) return;

    final now = DateTime.now();
    final last = _lastDetectionTime[eventType];
    if (last != null && now.difference(last) < _cooldownDuration) return;
    if (!_criticalEvents.contains(eventType) && !_passesTemporalConfirmation(eventType, now)) return;
    _emitEvent(eventType, confidence);
  }

  bool _passesTemporalConfirmation(String eventType, DateTime now) {
    _temporalBuffer[eventType] ??= <DateTime>[];
    final events = _temporalBuffer[eventType]!;
    events.removeWhere((t) => now.difference(t) > _temporalWindow);
    events.add(now);
    return events.length >= 2;
  }

  void _clearTemporalBuffer() {
    for (final list in _temporalBuffer.values) {
      list.clear();
    }
  }

  void _emitEvent(String eventType, double confidence) {
    final severity = _getSeverity(eventType);
    final event = SoundEvent(type: eventType, confidence: confidence, severity: severity);
    _lastDetectionTime[eventType] = DateTime.now();
    onSoundDetected?.call(event);
  }

  String? _mapLabelToEvent(String label) {
    final lower = label.toLowerCase();
    for (final entry in _labelMapping.entries) {
      for (final pattern in entry.value) {
        if (lower.contains(pattern.toLowerCase())) return entry.key;
      }
    }
    return null;
  }

  String _getSeverity(String eventType) {
    switch (eventType) {
      case 'Fire Alarm':
      case 'Siren':
      case 'Glass Break':
        return 'critical';
      case 'Doorbell':
      case 'Knock':
      case 'Phone':
      case 'Baby Cry':
        return 'warning';
      default:
        return 'info';
    }
  }

  bool processClassification(String label, double confidence) {
    if (!_monitoring) return false;
    final eventType = _mapLabelToEvent(label);
    if (eventType == null) return false;
    final threshold = _criticalEvents.contains(eventType) ? _criticalThreshold : _nonCriticalThreshold;
    if (confidence < threshold) return false;
    final now = DateTime.now();
    final last = _lastDetectionTime[eventType];
    if (last != null && now.difference(last) < _cooldownDuration) return false;
    if (!_criticalEvents.contains(eventType) && !_passesTemporalConfirmation(eventType, now)) return false;
    _emitEvent(eventType, confidence);
    return true;
  }

  void dispose() {
    stopMonitoring();
    _lastDetectionTime.clear();
    _clearTemporalBuffer();
  }
}
