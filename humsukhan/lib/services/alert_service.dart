import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import '../models/models.dart';

/// Service that handles alert feedback mechanisms:
/// - Haptic (vibration)
/// - Visual (in-app event banner)
/// - Screen flash (full-screen colour overlay)
/// - Flashlight (camera torch)
///
/// All feedback is gated by the [AlertPolicy] that was computed from
/// [SettingsProvider] at the call site.  Detection is independent of these
/// presentation preferences — filtering happens upstream in
/// [EnvironmentalProvider.processSoundEvent].
///
/// Flashlight patterns are serialized: only one pattern runs at a time and
/// a new alert cancels the previous pattern before starting a new one.
/// Flashlight failures are reported to [debugPrint] — never silently swallowed.
class AlertService {
  static final AlertService _instance = AlertService._();
  static AlertService get instance => _instance;
  AlertService._();

  static const _flashChannel = MethodChannel('com.humsukhan.flashlight');

  BuildContext? _overlayContext;
  OverlayEntry? _flashOverlay;
  OverlayEntry? _visualBanner;
  Timer? _flashTimer;
  Timer? _bannerTimer;
  bool _isFlashing = false;

  /// True while a torch flash pattern is running on the native side.
  bool _torchPatternRunning = false;

  /// Register the app's overlay context for screen flash / banner effects.
  void registerContext(BuildContext context) {
    _overlayContext = context;
  }

  /// Trigger all enabled alert feedback mechanisms for a detected event.
  ///
  /// [policy] is the normalized [AlertPolicy] snapshot computed from
  /// [SettingsProvider.alertPolicy].  [eventType] is the sound-event label
  /// (e.g. "Fire Alarm") used for the visual banner text.
  void triggerAlert(
    AlertPolicy policy, {
    String severity = 'warning',
    String eventType = '',
  }) {
    if (policy.haptic) {
      _triggerHaptic(severity);
    }
    if (policy.visual && eventType.isNotEmpty) {
      _triggerVisualBanner(eventType, severity);
    }
    if (policy.screenFlash) {
      _triggerScreenFlash(severity);
    }
    if (policy.flashlight) {
      _triggerFlashlight(severity);
    }
  }

  /// Trigger a test alert with ALL feedback mechanisms enabled,
  /// regardless of the current policy.  Used from Settings to let the
  /// user preview what alerts feel like.
  void triggerTestAlert() {
    _triggerHaptic('warning');
    _triggerVisualBanner('Test Alert', 'warning');
    _triggerScreenFlash('warning');
    _triggerFlashlight('warning');
  }

  /// Trigger haptic feedback based on severity.
  void _triggerHaptic(String severity) async {
    try {
      bool hasVibrator = await Vibration.hasVibrator();
      if (!hasVibrator) return;

      switch (severity) {
        case 'critical':
          // Urgent pattern: three short bursts
          await Vibration.vibrate(
            pattern: [0, 200, 100, 200, 100, 200],
            intensities: [255, 0, 255, 0, 255],
          );
          break;
        case 'warning':
          // Warning: double pulse
          await Vibration.vibrate(
            pattern: [0, 300, 150, 300],
            intensities: [200, 0, 200],
          );
          break;
        default:
          // Info: single short pulse
          await Vibration.vibrate(
            duration: 150,
            amplitude: 128,
          );
      }
    } catch (e) {
      debugPrint('Haptic alert failed: $e');
    }
  }

  /// Trigger a visible banner overlay for the detected event.
  ///
  /// The banner slides in at the top of the screen and stays visible for
  /// 3 seconds before auto-dismissing.  It shows the event type name and
  /// uses a severity-appropriate colour.
  void _triggerVisualBanner(String eventType, String severity) {
    if (_overlayContext == null) return;

    // Remove any existing banner before showing a new one.
    _bannerTimer?.cancel();
    _visualBanner?.remove();
    _visualBanner = null;

    Color bgColor;
    switch (severity) {
      case 'critical':
        bgColor = Colors.red.withValues(alpha: 0.85);
        break;
      case 'warning':
        bgColor = Colors.orange.withValues(alpha: 0.80);
        break;
      default:
        bgColor = Colors.blue.withValues(alpha: 0.75);
    }

    _visualBanner = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              eventType,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );

    Overlay.of(_overlayContext!).insert(_visualBanner!);

    _bannerTimer = Timer(const Duration(seconds: 3), () {
      _visualBanner?.remove();
      _visualBanner = null;
    });
  }

  /// Trigger a screen flash overlay effect.
  void _triggerScreenFlash(String severity) {
    if (_overlayContext == null) return;
    if (_isFlashing) return;

    Color flashColor;
    switch (severity) {
      case 'critical':
        flashColor = Colors.red.withValues(alpha: 0.6);
        break;
      case 'warning':
        flashColor = Colors.orange.withValues(alpha: 0.4);
        break;
      default:
        flashColor = Colors.blue.withValues(alpha: 0.3);
    }

    _isFlashing = true;
    _flashOverlay = OverlayEntry(
      builder: (context) => AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          color: flashColor,
        ),
      ),
    );

    Overlay.of(_overlayContext!).insert(_flashOverlay!);

    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 300), () {
      _flashOverlay?.remove();
      _flashOverlay = null;
      _isFlashing = false;
    });
  }

  /// Trigger the device flashlight (camera torch) using a native-side
  /// serialized flash pattern.  A new call cancels any running pattern
  /// first so overlapping alerts never fight each other.
  void _triggerFlashlight(String severity) async {
    try {
      // Cancel any in-progress pattern before starting a new one.
      if (_torchPatternRunning) {
        try { await _flashChannel.invokeMethod('cancelFlash'); } catch (_) {}
        _torchPatternRunning = false;
      }

      // Check availability — report clearly if no torch exists.
      final available = await _flashChannel.invokeMethod<bool>('isAvailable');
      if (available != true) {
        debugPrint('Flashlight: no torch-capable camera found on this device');
        return;
      }

      final flashCount = severity == 'critical' ? 4 : 2;
      _torchPatternRunning = true;
      await _flashChannel.invokeMethod('flashPattern', {
        'count': flashCount,
        'onMs': 200,
        'offMs': 150,
      });
      // The native side runs the pattern asynchronously; we don't await it.
      // Mark as done after a reasonable upper-bound delay.
      final totalMs = flashCount * (200 + 150) + 200;
      Timer(Duration(milliseconds: totalMs), () {
        _torchPatternRunning = false;
      });
    } on PlatformException catch (e) {
      _torchPatternRunning = false;
      debugPrint('Flashlight alert failed (${e.code}): ${e.message}');
    } catch (e) {
      _torchPatternRunning = false;
      debugPrint('Flashlight alert failed: $e');
    }
  }

  /// Stop all active alerts, including any running torch pattern.
  void stopAll() {
    _flashTimer?.cancel();
    _bannerTimer?.cancel();
    _flashOverlay?.remove();
    _flashOverlay = null;
    _visualBanner?.remove();
    _visualBanner = null;
    _isFlashing = false;
    if (_torchPatternRunning) {
      _torchPatternRunning = false;
      try { _flashChannel.invokeMethod('cancelFlash'); } catch (_) {}
    }
    try {
      Vibration.cancel();
    } catch (_) {}
  }

  void dispose() {
    stopAll();
  }
}
