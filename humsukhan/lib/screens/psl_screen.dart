import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../providers/speech_provider.dart';
import '../theme/app_theme.dart';
import '../services/psl_recognition_service.dart';
import '../l10n/app_strings.dart';

/// Experimental hand-shape recognition screen.
///
/// Shows camera feed with heuristic hand-shape detection, recognised
/// shape labels, and accumulated text. The current implementation uses
/// skin-colour thresholding — it is NOT a full sign-language translator.
class PslScreen extends StatefulWidget {
  const PslScreen({super.key});

  @override
  State<PslScreen> createState() => _PslScreenState();
}

class _PslScreenState extends State<PslScreen> {
  final PslRecognitionService _psl = PslRecognitionService.instance;
  StreamSubscription? _subscription;
  bool _isInitializing = true;
  bool _cameraReady = false;
  String _currentGesture = '';
  String _detectedText = '';
  double _matchStrength = 0;

  @override
  void initState() {
    super.initState();
    _initializePsl();
  }

  Future<void> _initializePsl() async {
    try {
      final success = await _psl.initialize();
      if (success && mounted) {
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
      } else if (mounted) {
        setState(() => _isInitializing = false);
      }
    } catch (e) {
      debugPrint('Hand-shape screen init error: $e');
      if (mounted) setState(() => _isInitializing = false);
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

          // Gesture indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTokens.deepSage.withValues(alpha: 0.1),
            child: Row(
              children: [
                Icon(
                  _cameraReady ? Icons.pan_tool : Icons.videocam_off,
                  color: _cameraReady ? AppTokens.deepSage : AppTokens.warning,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentGesture.isNotEmpty
                        ? s.shapeLabel(_currentGesture)
                        : (_cameraReady ? s.holdHandInGuide : s.cameraNotAvailable),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _cameraReady ? AppTokens.deepSage : AppTokens.warning,
                    ),
                  ),
                ),
                if (_matchStrength > 0 && _currentGesture.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTokens.deepSage.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                    ),
                    child: Text(
                      s.pslDetected,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppTokens.deepSage,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Detected text display
          Expanded(
            flex: 2,
            child: Container(
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
                        color: AppTokens.pureWhite,
                        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                        border: Border.all(
                          color: AppTokens.borderSage.withValues(alpha: 0.5),
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
                              ? AppTokens.textMuted
                              : AppTokens.textDeepForest,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Limitation notice
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppTokens.warning.withValues(alpha: 0.08),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: AppTokens.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.pslExperimentalNotice,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTokens.warning,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Action buttons
          Container(
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
                            ? AppTokens.error
                            : AppTokens.deepSage,
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
                    icon: const Icon(Icons.clear_all, color: AppTokens.deepSage),
                    label: Text(
                      s.pslClear,
                      style: const TextStyle(
                        color: AppTokens.deepSage,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      side: const BorderSide(color: AppTokens.deepSage),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(AppStrings s) {
    if (_isInitializing) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                s.initializingCamera,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    if (!_cameraReady || _psl.cameraController == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off, size: 64, color: Colors.white38),
              SizedBox(height: 16),
              Text(
                s.cameraNotAvailable,
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                s.cameraRequiresAccess,
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_psl.cameraController!),
          // Overlay guide
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
}
