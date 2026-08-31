import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class SettingsProvider extends ChangeNotifier {
  /// Completes once [_loadSettings] has finished reading SharedPreferences.
  final Completer<void> _initCompleter = Completer<void>();

  /// Whether local preferences have been loaded from disk.
  bool get isLoaded => _initCompleter.isCompleted;

  /// A future that resolves once persisted settings are available.
  /// Consumers should await this before reading any persisted value
  /// (e.g. [isOnboardingComplete]) to avoid the default-false race.
  Future<void> get ready => _initCompleter.future;

  bool _isDarkMode = false;
  bool _isHighContrast = false;
  bool _isLargeText = false;
  double _captionTextSize = 24.0;
  bool _hapticAlerts = true;
  bool _visualAlerts = true;
  bool _flashAlerts = false;
  bool _screenFlashAlerts = true;
  bool _simplifiedLanguage = false;
  String _captionLanguage = 'English';
  String _appLanguage = 'en';
  int _defaultRetentionDays = 7;
  bool _isOnboardingComplete = false;

  /// True when the device has a torch-capable camera.  Queried once from
  /// the native layer at startup; stays false on iOS (torch not implemented).

  /// Per-event-type allow list.  All supported event types from
  /// [SoundDetectionService.supportedEvents] are included and enabled by
  /// default.  Events whose type is not in this map (or is set to false)
  /// are silently dropped before they enter alert history.
  final Map<String, bool> _allowedAlerts = {
    'Fire Alarm': true,
    'Siren': true,
    'Doorbell': true,
    'Knock': true,
    'Phone': true,
    'Baby Cry': true,
    'Alarm Clock': true,
    'Vehicle Horn': true,
    'Glass Break': true,
    'Dog Bark': true,
  };

  /// Whether the device has a torch-capable camera.
  bool _flashlightAvailable = false;

  // Getters
  bool get isDarkMode => _isDarkMode;
  bool get isHighContrast => _isHighContrast;
  bool get isLargeText => _isLargeText;
  double get captionTextSize => _captionTextSize;
  bool get hapticAlerts => _hapticAlerts;
  bool get visualAlerts => _visualAlerts;
  bool get flashAlerts => _flashAlerts;
  bool get screenFlashAlerts => _screenFlashAlerts;
  bool get simplifiedLanguage => _simplifiedLanguage;
  String get captionLanguage => _captionLanguage;
  String get appLanguage => _appLanguage;
  int get defaultRetentionDays => _defaultRetentionDays;
  bool get isOnboardingComplete => _isOnboardingComplete;
  bool get flashlightAvailable => _flashlightAvailable;
  Map<String, bool> get allowedAlerts => Map.unmodifiable(_allowedAlerts);

  /// Returns a normalized [AlertPolicy] snapshot reflecting the current
  /// preference values.  Because this is a computed getter, any toggle
  /// immediately produces a new policy — no restart required.
  AlertPolicy get alertPolicy => AlertPolicy(
    haptic: _hapticAlerts,
    visual: _visualAlerts,
    screenFlash: _screenFlashAlerts,
    flashlight: _flashAlerts,
    allowedAlerts: _allowedAlerts.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toSet(),
  );

  ThemeMode get themeMode {
    return _isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  /// The desired text scale factor based on the user's large-text setting.
  /// The [main.dart] builder combines this with the system text scale to
  /// produce the final effective scale.  1.0 = default, 1.3 = large.
  double get textScaleFactor => _isLargeText ? 1.3 : 1.0;

  SettingsProvider() {
    _loadSettings();
    _queryFlashlightAvailability();
  }

  /// Query the native layer once to determine if a torch-capable camera exists.
  /// On iOS this always returns false (torch not implemented).
  Future<void> _queryFlashlightAvailability() async {
    if (!Platform.isAndroid) {
      _flashlightAvailable = false;
      return;
    }
    try {
      const channel = MethodChannel('com.humsukhan.flashlight');
      _flashlightAvailable = await channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      _flashlightAvailable = false;
    }
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool('darkMode') ?? false;
    _isHighContrast = prefs.getBool('highContrast') ?? false;
    _isLargeText = prefs.getBool('largeText') ?? false;
    _captionTextSize = prefs.getDouble('captionTextSize') ?? 24.0;
    _hapticAlerts = prefs.getBool('hapticAlerts') ?? true;
    _visualAlerts = prefs.getBool('visualAlerts') ?? true;
    _flashAlerts = prefs.getBool('flashAlerts') ?? false;
    _screenFlashAlerts = prefs.getBool('screenFlashAlerts') ?? true;
    _simplifiedLanguage = prefs.getBool('simplifiedLanguage') ?? false;
    _captionLanguage = prefs.getString('captionLanguage') ?? 'English';
    _appLanguage = prefs.getString('appLanguage') ?? 'en';
    _defaultRetentionDays = prefs.getInt('defaultRetentionDays') ?? 7;
    _isOnboardingComplete = prefs.getBool('onboardingComplete') ?? false;

    // Load persisted allowed-alerts map (JSON-encoded).
    final rawAllowed = prefs.getString('allowedAlerts');
    if (rawAllowed != null) {
      try {
        final decoded = jsonDecode(rawAllowed) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          _allowedAlerts[entry.key] = entry.value as bool;
        }
      } catch (_) {
        // Corrupt data — keep defaults.
      }
    }
    notifyListeners();
    if (!_initCompleter.isCompleted) _initCompleter.complete();
  }

  Future<void> _save(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  void toggleDarkMode() {
    _isDarkMode = !_isDarkMode;
    _save('darkMode', _isDarkMode);
    notifyListeners();
  }

  void toggleHighContrast() {
    _isHighContrast = !_isHighContrast;
    _save('highContrast', _isHighContrast);
    notifyListeners();
  }

  void toggleLargeText() {
    _isLargeText = !_isLargeText;
    _save('largeText', _isLargeText);
    notifyListeners();
  }

  void setCaptionTextSize(double size) {
    _captionTextSize = size.clamp(16.0, 48.0);
    _save('captionTextSize', _captionTextSize);
    notifyListeners();
  }

  void toggleHapticAlerts() {
    _hapticAlerts = !_hapticAlerts;
    _save('hapticAlerts', _hapticAlerts);
    notifyListeners();
  }

  void toggleVisualAlerts() {
    _visualAlerts = !_visualAlerts;
    _save('visualAlerts', _visualAlerts);
    notifyListeners();
  }

  void toggleFlashAlerts() {
    _flashAlerts = !_flashAlerts;
    _save('flashAlerts', _flashAlerts);
    notifyListeners();
  }

  void toggleScreenFlashAlerts() {
    _screenFlashAlerts = !_screenFlashAlerts;
    _save('screenFlashAlerts', _screenFlashAlerts);
    notifyListeners();
  }

  void toggleSimplifiedLanguage() {
    _simplifiedLanguage = !_simplifiedLanguage;
    _save('simplifiedLanguage', _simplifiedLanguage);
    notifyListeners();
  }

  void setCaptionLanguage(String lang) {
    _captionLanguage = lang;
    _save('captionLanguage', lang);
    notifyListeners();
  }

  void setAppLanguage(String langCode) {
    _appLanguage = langCode;
    _save('appLanguage', langCode);
    notifyListeners();
  }

  void setDefaultRetentionDays(int days) {
    _defaultRetentionDays = days;
    _save('defaultRetentionDays', days);
    notifyListeners();
  }

  void toggleAllowedAlert(String alertType) {
    _allowedAlerts[alertType] = !(_allowedAlerts[alertType] ?? true);
    _saveAllowedAlerts();
    notifyListeners();
  }

  /// Persist the entire allowed-alerts map as a JSON string.
  Future<void> _saveAllowedAlerts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('allowedAlerts', jsonEncode(_allowedAlerts));
  }

  /// Mark onboarding as completed and **persist** the flag before returning.
  ///
  /// The caller must await this method so the flag is guaranteed to be on
  /// disk before any navigation transition occurs.
  Future<void> completeOnboarding() async {
    _isOnboardingComplete = true;
    await _save('onboardingComplete', true);
    notifyListeners();
  }
}
