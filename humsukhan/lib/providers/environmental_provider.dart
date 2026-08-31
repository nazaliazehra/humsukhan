import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/models.dart';
import '../services/alert_history_store.dart';
import '../services/alert_service.dart';
import '../services/environmental_monitoring_bridge.dart';
import '../services/sound_detection_service.dart';
import '../services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'settings_provider.dart';

/// Fine-grained monitoring status that accurately reflects which
/// subsystem is active, starting, or has failed.
enum MonitoringStatus {
  /// Monitoring is not running.
  off,

  /// Permission is being requested or has been denied.
  permissionDenied,

  /// The audio recorder could not be created or started.
  recorderFailed,

  /// The environmental sound-classification model is not installed.
  modelUnavailable,

  /// The audio tagger failed to initialise.
  taggerFailed,

  /// An unexpected error occurred.
  error,

  /// The monitoring pipeline is starting up (permission granted,
  /// recorder and model initialising).
  starting,

  /// Monitoring is active and processing audio.
  active,

  /// Monitoring is shutting down.
  stopping,
}

class EnvironmentalProvider extends ChangeNotifier {
  EnvironmentalProvider() {
    unawaited(_initializeNativeBridge());
  }

  final EnvironmentalMonitoringBridge _bridge = EnvironmentalMonitoringBridge.instance;
  final SoundDetectionService _soundService = SoundDetectionService.instance;
  final AlertHistoryStore _historyStore = AlertHistoryStore();
  final List<SoundEvent> _alertHistory = [];
  SoundEvent? _currentAlert;
  MonitoringStatus _status = MonitoringStatus.off;
  String? _lastAlertType;
  DateTime? _lastAlertTime;
  SettingsProvider? _settingsProvider;
  bool _bridgeInitialized = false;

  static const _cooldownDuration = Duration(seconds: 30);
  static const _minConfidence = 0.6;

  /// Access the persistent history store (e.g. for testing).
  AlertHistoryStore get historyStore => _historyStore;

  void setSettingsProvider(SettingsProvider settings) => _settingsProvider = settings;

  /// Set the active user so that alert history is scoped correctly.
  /// Loads persisted history from local storage and notifies listeners.
  /// Pass an empty string for anonymous users.
  Future<void> setUser(String userId) async {
    await _historyStore.setUser(userId);
    _alertHistory
      ..clear()
      ..addAll(_historyStore.events);
    _currentAlert = _alertHistory.isNotEmpty ? _alertHistory.last : null;
    notifyListeners();
  }

  // ── Status getters ─────────────────────────────────────────────────

  MonitoringStatus get status => _status;

  /// Whether monitoring is in any active/starting state (for backward compatibility).
  bool get monitoringEnabled =>
      _status == MonitoringStatus.active || _status == MonitoringStatus.starting;

  String get monitoringState => _status.name.toUpperCase();

  bool get isStarting => _status == MonitoringStatus.starting;

  bool get isStopping => _status == MonitoringStatus.stopping;

  bool get hasError =>
      _status == MonitoringStatus.error ||
      _status == MonitoringStatus.permissionDenied ||
      _status == MonitoringStatus.recorderFailed ||
      _status == MonitoringStatus.modelUnavailable ||
      _status == MonitoringStatus.taggerFailed;

  bool get isProcessing => false;
  bool get isLocal => monitoringEnabled;

  String get environmentalStatus {
    switch (_status) {
      case MonitoringStatus.active:
        return 'Offline / Local';
      case MonitoringStatus.starting:
        return 'Starting…';
      case MonitoringStatus.permissionDenied:
        return 'Microphone permission required';
      case MonitoringStatus.recorderFailed:
        return 'Microphone recorder failed';
      case MonitoringStatus.modelUnavailable:
        return 'Environmental model not installed';
      case MonitoringStatus.taggerFailed:
        return 'Audio tagger initialization failed';
      case MonitoringStatus.error:
        return 'Error';
      case MonitoringStatus.stopping:
        return 'Stopping…';
      case MonitoringStatus.off:
        return 'Off';
    }
  }

  List<SoundEvent> get alertHistory => List.unmodifiable(_alertHistory);
  SoundEvent? get currentAlert => _currentAlert;

  List<SoundEvent> get recentAlerts {
    final sorted = List<SoundEvent>.from(_alertHistory);
    sorted.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.take(20).toList();
  }

  static const Map<String, String> alertDescriptions = {
    'Fire Alarm': 'A possible fire alarm was detected. Please check your surroundings.',
    'Siren': 'A siren sound was detected nearby.',
    'Doorbell': 'A doorbell sound was detected.',
    'Knock': 'A knocking sound was detected at a door.',
    'Phone': 'A phone ringtone was detected.',
    'Phone/Ringtone': 'A phone ringtone was detected.',
    'Alarm Clock': 'An alarm clock sound was detected.',
    'Baby Cry': 'A baby crying sound was detected.',
    'Vehicle Horn': 'A vehicle horn was detected.',
    'Glass Break': 'A possible glass break was detected.',
    'Dog Bark': 'A dog bark was detected.',
  };

  Future<void> _initializeNativeBridge() async {
    if (_bridgeInitialized) return;
    _bridgeInitialized = true;
    await _bridge.initialize(onChange: _handleNativeChange);
    // Map the bridge's coarse state to our fine-grained status.
    final bridgeState = _bridge.state;
    _status = _mapBridgeState(bridgeState);
    notifyListeners();
  }

  MonitoringStatus _mapBridgeState(String bridgeState) {
    switch (bridgeState) {
      case 'ACTIVE':
        return MonitoringStatus.active;
      case 'STARTING':
        return MonitoringStatus.starting;
      case 'STOPPING':
        return MonitoringStatus.stopping;
      case 'ERROR':
        return MonitoringStatus.error;
      default:
        return MonitoringStatus.off;
    }
  }

  void _handleNativeChange(String state, Map<String, dynamic>? event) {
    _status = _mapBridgeState(state);
    if (event != null) {
      final type = event['type']?.toString();
      final confidence = (event['confidence'] as num?)?.toDouble();
      final severity = event['severity']?.toString();
      if (type != null && confidence != null) {
        processSoundEvent(SoundEvent(type: type, confidence: confidence, severity: severity ?? 'warning'));
      }
    }
    notifyListeners();
  }

  // ── Toggle monitoring ──────────────────────────────────────────────

  Future<void> toggleMonitoring() async {
    if (monitoringEnabled) {
      _status = MonitoringStatus.stopping;
      notifyListeners();
      _soundService.stopMonitoring();
      await _bridge.stop();
      _status = MonitoringStatus.off;
      notifyListeners();
      return;
    }

    // Step 1: Request microphone permission.
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      _status = MonitoringStatus.permissionDenied;
      notifyListeners();
      return;
    }

    // Step 2: Start the pipeline.
    _status = MonitoringStatus.starting;
    notifyListeners();

    if (Platform.isIOS) {
      // iOS: native configures AVAudioSession; Flutter owns the local detector.
      if (!await _bridge.start()) {
        _status = MonitoringStatus.error;
        notifyListeners();
        return;
      }
      _soundService.onSoundDetected = processSoundEvent;
      final result = await _soundService.startMonitoring(permissionAlreadyGranted: true);
      _status = _mapStartupResult(result);
    } else {
      // Android: the foreground service owns the pipeline.
      final started = await _bridge.start();
      if (!started) {
        // The bridge couldn't start. The specific error will come through
        // the EventChannel once the background engine reports its state.
        _status = MonitoringStatus.error;
      }
    }
    notifyListeners();
  }

  /// Map a [StartupResult] to a [MonitoringStatus].
  MonitoringStatus _mapStartupResult(StartupResult result) {
    switch (result) {
      case StartupResult.success:
        return MonitoringStatus.active;
      case StartupResult.permissionDenied:
        return MonitoringStatus.permissionDenied;
      case StartupResult.recorderFailed:
        return MonitoringStatus.recorderFailed;
      case StartupResult.modelUnavailable:
        return MonitoringStatus.modelUnavailable;
      case StartupResult.taggerFailed:
        return MonitoringStatus.taggerFailed;
      case StartupResult.unknownError:
        return MonitoringStatus.error;
    }
  }

  bool processSoundEvent(SoundEvent event) {
    if (event.confidence < _minConfidence) return false;

    // Filter by allowed-alerts policy BEFORE the event enters history.
    final settings = _settingsProvider;
    if (settings != null && !settings.alertPolicy.isAllowed(event.type)) {
      return false;
    }

    if (_lastAlertType == event.type && _lastAlertTime != null &&
        DateTime.now().difference(_lastAlertTime!) < _cooldownDuration) {
      return false;
    }

    _alertHistory.add(event);
    _currentAlert = event;
    _lastAlertType = event.type;
    _lastAlertTime = DateTime.now();

    // Persist to local store (fire-and-forget).
    unawaited(_historyStore.addEvent(event));
    _syncToSupabase(event);

    notifyListeners();

    if (settings != null) {
      AlertService.instance.triggerAlert(
        settings.alertPolicy,
        severity: event.severity,
        eventType: event.type,
      );
    }
    return true;
  }

  void dismissAlert([String? eventId]) {
    final id = eventId ?? _currentAlert?.id;
    if (id != null) {
      final idx = _alertHistory.indexWhere((a) => a.id == id);
      if (idx != -1) _alertHistory[idx] = _alertHistory[idx].copyWith(dismissed: true);
      unawaited(_historyStore.dismiss(id));
    }
    if (_currentAlert?.id == id) _currentAlert = null;
    notifyListeners();
  }

  void clearHistory() {
    _alertHistory.clear();
    _currentAlert = null;
    unawaited(_historyStore.clear());
    notifyListeners();
  }

  void _syncToSupabase(SoundEvent event) {
    final supabase = SupabaseService.instance;
    if (!supabase.isAuthenticated) return;
    final client = supabase.client;
    if (client == null) return;
    unawaited(_insertAlertEvent(client, supabase.userId, event));
  }

  Future<void> _insertAlertEvent(
      SupabaseClient client, String userId, SoundEvent event) async {
    try {
      await client.from('alert_events').insert({
        'id': event.id,
        'user_id': userId,
        'type': event.type,
        'confidence': event.confidence,
        'severity': event.severity,
        'dismissed': event.dismissed,
        'created_at': event.timestamp.toIso8601String(),
      });
    } catch (_) {
      // Network or schema mismatch — silently ignore.
    }
  }

  @override
  void dispose() {
    unawaited(_bridge.dispose());
    super.dispose();
  }
}
