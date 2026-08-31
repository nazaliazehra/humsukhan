import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/speech_provider.dart';
import '../theme/app_theme.dart';
import '../services/psl_recognition_service.dart';
import '../l10n/app_strings.dart';

/// PSL (Pakistani Sign Language) recognition screen.
///
/// Shows camera feed with hand-shape detection, recognised shape labels,
/// and accumulated text.
///
/// ## Recognition status
///
/// The screen displays clear status indicators:
/// - **Initializing** — camera or recognition engine is starting up.
/// - **Recognition active** — frames are being processed; show your hand.
/// - **Recognition paused** — e.g. during camera switch.
/// - **Error** — camera unavailable or permission denied.
///
/// ## Camera control
///
/// A toggle button allows switching between front and rear cameras.
/// Switching properly disposes the current camera and reinitializes
/// with the other lens direction.
///
/// ## Model note
///
/// The current recognition uses skin-colour heuristics — it is NOT a
/// full sign-language translator.  When a real trained PSL model is
/// available, it should be integrated in [PslRecognitionService] at the
/// [_processFrameInIsolate] integration point.
class PslScreen extends StatefulWidget {
  const PslScreen({super.key});

  @override
  State<PslScreen> createState() => _PslScreenState();
}

class _PslScreenState extends State<PslScreen> {
  final PslRecognitionService _psl = PslRecognitionService.instance;
  StreamSubscription? _subscription;
  bool _isInitializing = true;
  bool _isSwitchingCamera = false;
  bool _cameraReady = false;
  String _currentGesture = '';
  String _detectedText = '';
  double _matchStrength = 0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializePsl();
  }

  Future<void> _initializePsl() async {
    if (!mounted) return;

    setState(() {
      _isInitializing = true;
      _errorMessage = null;
    });

    try {
      final success = await _psl.initialize();
      if (!mounted) return;

      if (success) {
        setState(() {
          _isInitializing = false;
          _cameraReady = true;
        });
        await _psl.startProcessing();
        _subscription = _psl.onResult.listen((result) {
          if (!mounted) return;
          setState(() {
            _currentGesture = result.gestureName;
            _detectedText = result.accumulatedText;
            _matchStrength = result.matchStrength;
          });
        });
      } else {
        setState(() {
          _isInitializing = false;
          _cameraReady = false;
          _errorMessage = 'Camera initialization failed';
        });
      }
    } catch (e) {
      debugPrint('PSL screen init error: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _cameraReady = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _toggleCamera() async {
    if (_isSwitchingCamera) return;

    setState(() {
      _isSwitchingCamera = true;
      _cameraReady = false;
    });

    // Cancel existing subscription before switching.
    _subscription?.cancel();

    try {
      final success = await _psl.switchCamera();
      if (!mounted) return;

      if (success) {
        setState(() {
          _cameraReady = true;
          _isSwitchingCamera = false;
        });
        // Re-subscribe to results.
        _subscription = _psl.onResult.listen((result) {
          if (!mounted) return;
          setState(() {
            _currentGesture = result.gestureName;
            _detectedText = result.accumulatedText;
            _matchStrength = result.matchStrength;
          });
        });
      } else {
        setState(() {
          _cameraReady = false;
          _isSwitchingCamera = false;
          _errorMessage = 'Failed to switch camera';
        });
        // Try to re-initialize with original camera.
        await _initializePsl();
      }
    } catch (e) {
      debugPrint('PSL camera switch error: $e');
      if (mounted) {
        setState(() {
          _isSwitchingCamera = false;
          _errorMessage = 'Camera switch failed';
        });
        // Try to re-initialize.
        await _initializePsl();
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _psl.stopProcessing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.handShapeTitle),
        actions: [
          if (_detectedText.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                _psl.clearText();
                setState(() {
                  _detectedText = '';
                  _currentGesture = '';
                });
              },
              tooltip: s.clearText,
            ),
        ],
      ),
      body: Column(
        children: [
          // Camera preview
          Expanded(
            flex: 3,
            child: _buildCameraPreview(s),
          ),

          // Recognition status + gesture indicator
          _buildRecognitionStatus(s),

          // Detected text display
          Expanded(
            flex: 2,
            child: _buildDetectedTextPanel(s),
          ),

          // Model limitation notice
          _buildModelNotice(s),

          // Action buttons
          _buildActionButtons(s),
        ],
      ),
    );
  }

  // ── Camera preview ────────────────────────────────────────────────

  Widget _buildCameraPreview(AppStrings s) {
    // Switching camera state.
    if (_isSwitchingCamera) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                s.cameraSwitching,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    // Initializing state.
    if (_isInitializing) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                s.initializingCamera,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    // Error state.
    if (_errorMessage != null || !_cameraReady || _psl.cameraController == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off, size: 64, color: Colors.white38),
                const SizedBox(height: 16),
                Text(
                  s.cameraNotAvailable,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  s.cameraRequiresAccess,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() => _errorMessage = null);
                    _initializePsl();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Camera preview with overlay.
    return ClipRRect(
      borderRadius: BorderRadius.circular(0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_psl.cameraController!),

          // Hand guide overlay
          Center(
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.5),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(
                  s.holdHandOverlay,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),

          // Camera switch button (top-right corner)
          Positioned(
            top: 12,
            right: 12,
            child: _buildCameraToggleButton(s),
          ),

          // Camera label (top-left corner)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _psl.isFrontCamera ? Icons.camera_front : Icons.camera_rear,
                    color: Colors.white70,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _psl.isFrontCamera ? s.frontCameraLabel : s.rearCameraLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          // Instructions
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                s.pslInstructions,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraToggleButton(AppStrings s) {
    return GestureDetector(
      onTap: _isSwitchingCamera ? null : _toggleCamera,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          shape: BoxShape.circle,
        ),
        child: _isSwitchingCamera
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              )
            : Icon(
                _psl.isFrontCamera
                    ? Icons.cameraswitch
                    : Icons.cameraswitch,
                color: Colors.white,
                size: 20,
              ),
      ),
    );
  }

  // ── Recognition status bar ────────────────────────────────────────

  Widget _buildRecognitionStatus(AppStrings s) {
    Color bgColor;
    Color fgColor;
    IconData icon;
    String text;

    if (_isSwitchingCamera) {
      bgColor = AppTheme.warningLight.withValues(alpha: 0.1);
      fgColor = AppTheme.warningLight;
      icon = Icons.hourglass_empty;
      text = s.cameraSwitching;
    } else if (_isInitializing) {
      bgColor = cs.surfaceContainerHighest.withValues(alpha: 0.3);
      fgColor = cs.onSurfaceVariant;
      icon = Icons.mic_none;
      text = s.recognitionStarting;
    } else if (!_cameraReady) {
      bgColor = Colors.redAccent.withValues(alpha: 0.1);
      fgColor = Colors.redAccent;
      icon = Icons.error_outline;
      text = _errorMessage ?? s.cameraNotAvailable;
    } else if (_psl.isProcessing && _currentGesture.isNotEmpty) {
      bgColor = AppTheme.successLight.withValues(alpha: 0.08);
      fgColor = AppTheme.successLight;
      icon = Icons.pan_tool;
      text = s.shapeLabel(_currentGesture);
    } else if (_psl.isProcessing) {
      bgColor = AppTheme.successLight.withValues(alpha: 0.08);
      fgColor = AppTheme.successLight;
      icon = Icons.fiber_manual_record;
      text = s.recognitionActive;
    } else {
      bgColor = cs.surfaceContainerHighest.withValues(alpha: 0.3);
      fgColor = cs.onSurfaceVariant;
      icon = Icons.pause_circle_outline;
      text = s.recognitionPaused;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: bgColor,
      child: Row(
        children: [
          Icon(icon, color: fgColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: fgColor,
              ),
            ),
          ),
          if (_matchStrength > 0 && _currentGesture.isNotEmpty && _currentGesture != 'Cleared')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.successLight.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppTheme.radiusFull),
              ),
              child: Text(
                s.pslDetected,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.successLight,
                ),
              ),
            ),
        ],
      ),
    );
  }

  ColorScheme get cs => Theme.of(context).colorScheme;

  // ── Detected text panel ───────────────────────────────────────────

  Widget _buildDetectedTextPanel(AppStrings s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.detectedTextHeader,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                _detectedText.isEmpty
                    ? s.pslPlaceholder
                    : _detectedText,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: _detectedText.isEmpty
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Model limitation notice ───────────────────────────────────────

  Widget _buildModelNotice(AppStrings s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppTheme.warningLight.withValues(alpha: 0.08),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: AppTheme.warningLight),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              s.noTrainedModel,
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.warningLight,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────

  Widget _buildActionButtons(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // Speak button
          Expanded(
            child: Consumer<SpeechProvider>(
              builder: (_, speech, child) => ElevatedButton.icon(
                onPressed: _detectedText.isNotEmpty
                    ? () => speech.speak(_detectedText)
                    : null,
                icon: Icon(
                  speech.isSpeaking ? Icons.stop : Icons.volume_up,
                  color: Colors.white,
                ),
                label: Text(
                  speech.isSpeaking ? s.pslStop : s.pslSpeak,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: speech.isSpeaking
                      ? AppTheme.errorLight
                      : Theme.of(context).colorScheme.primary,
                  minimumSize: const Size(0, 52),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Clear button
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _detectedText.isNotEmpty
                  ? () {
                      _psl.clearText();
                      setState(() {
                        _detectedText = '';
                        _currentGesture = '';
                      });
                    }
                  : null,
              icon: Icon(Icons.clear_all, color: Theme.of(context).colorScheme.primary),
              label: Text(
                s.pslClear,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 52),
                side: BorderSide(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
