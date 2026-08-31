import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// PSL (Pakistani Sign Language) recognition service.
///
/// ## Architecture
///
/// This service manages the camera lifecycle and frame-processing pipeline.
/// It currently uses **skin-colour heuristics** for hand detection — it is
/// NOT a full sign-language translator.
///
/// ### Model integration point
///
/// The function [_processFrameInIsolate] is the single integration point
/// where a real hand-landmark model (e.g. MediaPipe Hands, TFLite) should
/// be plugged in.  When a trained PSL model is available:
///
/// 1. Replace [_processFrameInIsolate] with a function that runs the model
///    on the camera frame bytes.
/// 2. The model must output 21 [HandLandmark] points in the MediaPipe Hands
///    landmark order (wrist, thumb×4, index×4, middle×4, ring×4, pinky×4).
/// 3. The downstream [_classifyGesture] method already consumes
///    [HandLandmark] lists in that format, so the classifier can remain
///    unchanged if the new model produces compatible output.
///
/// ### Current limitations (heuristic mode)
///
/// - Hand detection is based on skin colour, not a trained model.
/// - Landmarks are geometrically placed at fixed offsets from the skin
///   centroid — they do NOT represent actual finger positions.
/// - Gesture classification uses finger-count heuristics on estimated
///   landmarks — it cannot distinguish signs requiring precise joint
///   angles, motion, or context.
/// - Left/right hand discrimination is unreliable with the front camera.
class PslRecognitionService {
  PslRecognitionService._();
  static PslRecognitionService? _instance;
  static PslRecognitionService get instance => _instance ??= PslRecognitionService._();

  CameraController? _cameraController;
  final StreamController<PslResult> _resultController =
      StreamController<PslResult>.broadcast();

  bool _isInitialized = false;
  bool _isProcessing = false;
  String _accumulatedText = '';
  DateTime? _lastSignTime;
  DateTime? _lastSpaceTime;

  /// The currently active camera lens direction.
  CameraLensDirection _currentLensDirection = CameraLensDirection.front;

  static const Duration _signDebounce = Duration(milliseconds: 800);
  static const Duration _spaceTimeout = Duration(seconds: 2);

  Stream<PslResult> get onResult => _resultController.stream;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  String get accumulatedText => _accumulatedText;
  CameraController? get cameraController => _cameraController;
  CameraLensDirection get currentLensDirection => _currentLensDirection;
  bool get isFrontCamera => _currentLensDirection == CameraLensDirection.front;

  /// Initialize camera with the given [lensDirection].
  ///
  /// If a camera is already initialized, it is disposed first.
  Future<bool> initialize({CameraLensDirection lensDirection = CameraLensDirection.front}) async {
    // Dispose existing camera if switching.
    await _disposeCamera();

    _currentLensDirection = lensDirection;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('PslRecognition: No cameras available');
        _isInitialized = false;
        return false;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == lensDirection,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      _isInitialized = true;

      debugPrint('PslRecognition: Camera initialized (${camera.name}, ${camera.lensDirection})');
      return true;
    } catch (e) {
      debugPrint('PslRecognition initialization error: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Switch between front and rear camera.
  ///
  /// Properly disposes the current camera, reinitializes with the other
  /// camera, and restarts processing if it was active.
  Future<bool> switchCamera() async {
    final newDirection = _currentLensDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    final wasProcessing = _isProcessing;

    if (wasProcessing) {
      stopProcessing();
    }

    final success = await initialize(lensDirection: newDirection);

    if (success && wasProcessing) {
      await startProcessing();
    }

    return success;
  }

  /// Start processing camera frames for hand-shape detection.
  Future<void> startProcessing() async {
    if (!_isInitialized || _cameraController == null) return;
    if (_isProcessing) return;

    _isProcessing = true;
    _accumulatedText = '';
    _lastSignTime = null;

    await _cameraController!.startImageStream((CameraImage image) {
      if (!_isProcessing) return;
      _processFrame(image);
    });

    debugPrint('PslRecognition: Processing started');
  }

  /// Stop processing frames.
  void stopProcessing() {
    _isProcessing = false;
    _cameraController?.stopImageStream();
    debugPrint('PslRecognition: Processing stopped');
  }

  /// Process a camera frame for hand detection and gesture classification.
  void _processFrame(CameraImage image) {
    if (!_isProcessing) return;

    _isProcessing = false; // Prevent re-entry

    compute(_processFrameInIsolate, _FrameData(
      planes: image.planes.map((p) => _PlaneData(
        bytes: p.bytes,
        bytesPerRow: p.bytesPerRow,
        bytesPerPixel: p.bytesPerPixel ?? 1,
      )).toList(),
      width: image.width,
      height: image.height,
      format: image.format.raw,
      isFrontCamera: _currentLensDirection == CameraLensDirection.front,
    )).then((result) {
      if (result != null) {
        _handleDetectionResult(result);
      }
      _isProcessing = true;
    }).catchError((e) {
      debugPrint('PslRecognition: isolate error: $e');
      _isProcessing = true;
    });
  }

  /// Handle a detection result from the isolate.
  void _handleDetectionResult(_DetectionResult result) {
    if (!result.handDetected) return;

    final now = DateTime.now();
    final gesture = _classifyGesture(result.landmarks);

    if (gesture != null) {
      if (_lastSignTime != null && now.difference(_lastSignTime!) < _signDebounce) {
        return;
      }

      if (_accumulatedText.isNotEmpty &&
          _lastSpaceTime != null &&
          now.difference(_lastSpaceTime!) > _spaceTimeout &&
          !gesture.isSpace) {
        _accumulatedText += ' ';
      }

      if (gesture.isSpace) {
        _accumulatedText += ' ';
        _lastSpaceTime = now;
      } else if (gesture.character != null) {
        _accumulatedText += gesture.character!;
        _lastSpaceTime = now;
      }

      _lastSignTime = now;

      _resultController.add(PslResult(
        character: gesture.character,
        gestureName: gesture.name,
        accumulatedText: _accumulatedText,
        matchStrength: result.matchStrength,
      ));
    }
  }

  /// Classify hand landmarks into a gesture label.
  ///
  /// Uses finger-count heuristics on estimated landmarks.  When a real
  /// model is integrated, this method will work on actual detected joint
  /// positions instead of estimated ones.
  _PslGesture? _classifyGesture(List<HandLandmark> landmarks) {
    if (landmarks.length < 21) return null;

    final thumbTip = landmarks[4];
    final indexTip = landmarks[8];
    final middleTip = landmarks[12];
    final ringTip = landmarks[16];
    final pinkyTip = landmarks[20];

    final thumbIp = landmarks[3];
    final indexPip = landmarks[6];
    final middlePip = landmarks[10];
    final ringPip = landmarks[14];
    final pinkyPip = landmarks[18];

    // A finger is "extended" if its tip is above (lower y value) its PIP joint.
    final indexExtended = indexTip.y < indexPip.y;
    final middleExtended = middleTip.y < middlePip.y;
    final ringExtended = ringTip.y < ringPip.y;
    final pinkyExtended = pinkyTip.y < pinkyPip.y;

    // Thumb: compare x-axis distance. With a mirrored front camera this
    // is ambiguous — it works for one hand but not the other.
    final thumbExtended = (thumbTip.x - thumbIp.x).abs() > 0.02;

    // ── Gesture → character label mapping ─────────────────────────────
    //
    // These labels are illustrative approximations used to demonstrate the
    // concept of hand-shape-to-text mapping. They are NOT validated PSL
    // finger-spelling signs.

    if (!indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Fist', character: null);
    }

    if (indexExtended && middleExtended && ringExtended && pinkyExtended) {
      if (thumbExtended) {
        return _PslGesture(name: 'Open Palm', isSpace: true);
      }
      return _PslGesture(name: 'Flat Hand', character: 'B');
    }

    if (indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Index Point', character: 'A');
    }

    if (indexExtended && middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'V Shape', character: 'V');
    }

    if (indexExtended && middleExtended && ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Three Fingers', character: 'W');
    }

    if (thumbExtended && !indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Thumb', character: 'T');
    }

    if (thumbExtended && indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'L Shape', character: 'L');
    }

    if (thumbExtended && !indexExtended && !middleExtended && !ringExtended && pinkyExtended) {
      return _PslGesture(name: 'Y Shape', character: 'Y');
    }

    if (!indexExtended && !middleExtended && !ringExtended && pinkyExtended) {
      return _PslGesture(name: 'Pinky', character: 'I');
    }

    if (!indexExtended && !middleExtended && ringExtended && pinkyExtended) {
      return _PslGesture(name: 'Two Fingers', character: 'U');
    }

    if (!indexExtended && middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Middle Point', character: 'D');
    }

    return null;
  }

  /// Clear accumulated text.
  void clearText() {
    _accumulatedText = '';
    _lastSignTime = null;
    _lastSpaceTime = null;
    _resultController.add(PslResult(
      character: null,
      gestureName: 'Cleared',
      accumulatedText: '',
      matchStrength: 0.0,
    ));
  }

  /// Dispose the camera controller without closing the stream controller.
  Future<void> _disposeCamera() async {
    try {
      if (_cameraController != null) {
        if (_cameraController!.value.isStreamingImages) {
          await _cameraController!.stopImageStream();
        }
        await _cameraController!.dispose();
      }
    } catch (e) {
      debugPrint('PslRecognition: camera dispose error: $e');
    }
    _cameraController = null;
    _isInitialized = false;
  }

  /// Reset and fully dispose.
  Future<void> dispose() async {
    stopProcessing();
    await _disposeCamera();
    _resultController.close();
  }
}

// ── Data classes ─────────────────────────────────────────────────────

/// A single hand landmark point.
///
/// In heuristic mode these are geometrically estimated from the skin-colour
/// centroid.  When a real model is integrated, these will contain actual
/// detected coordinates.
class HandLandmark {
  final double x;
  final double y;
  final double z;

  const HandLandmark({required this.x, required this.y, required this.z});
}

/// Internal gesture classification result.
class _PslGesture {
  final String name;
  final String? character;
  final bool isSpace;
  const _PslGesture({
    required this.name,
    this.character,
    this.isSpace = false,
  });
}

/// Result emitted for each recognised hand-shape.
///
/// [matchStrength] is the ratio of skin-colour pixels in the sampled
/// camera region — it indicates how much skin was visible, NOT how
/// confident a classification model is.
class PslResult {
  final String? character;
  final String gestureName;
  final String accumulatedText;
  final double matchStrength;

  const PslResult({
    required this.character,
    required this.gestureName,
    required this.accumulatedText,
    required this.matchStrength,
  });
}

// ── Isolate data ─────────────────────────────────────────────────────

/// Data passed to compute isolate for frame processing.
class _FrameData {
  final List<_PlaneData> planes;
  final int width;
  final int height;
  final int format;
  final bool isFrontCamera;

  const _FrameData({
    required this.planes,
    required this.width,
    required this.height,
    required this.format,
    required this.isFrontCamera,
  });
}

class _PlaneData {
  final Uint8List bytes;
  final int bytesPerRow;
  final int bytesPerPixel;

  const _PlaneData({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });
}

/// Internal detection result from the isolate.
class _DetectionResult {
  final bool handDetected;
  final List<HandLandmark> landmarks;

  /// Skin-pixel ratio in the sampled region (0.0–1.0).
  /// Not a classification confidence — see [PslResult.matchStrength].
  final double matchStrength;

  const _DetectionResult({
    required this.handDetected,
    required this.landmarks,
    required this.matchStrength,
  });
}

// ── Frame processing (isolate entry point) ──────────────────────────

/// Process a camera frame in an isolate.
///
/// **This is the single integration point for a real PSL model.**
///
/// Currently uses skin-colour thresholding as a heuristic prototype.
/// To integrate a real hand-landmark model:
///
/// 1. Load the TFLite/ONNX model weights into the isolate.
/// 2. Run inference on [frame.planes] bytes.
/// 3. Produce 21 [HandLandmark] points in MediaPipe Hands order.
/// 4. Return a [_DetectionResult] with `handDetected: true`.
///
/// The downstream [_classifyGesture] method already consumes
/// [HandLandmark] lists in the 21-point MediaPipe format.
_DetectionResult? _processFrameInIsolate(_FrameData frame) {
  if (frame.planes.isEmpty) return null;

  final yPlane = frame.planes[0].bytes;
  final uPlane = frame.planes.length > 1 ? frame.planes[1].bytes : null;
  final vPlane = frame.planes.length > 2 ? frame.planes[2].bytes : null;

  // Sample center region for skin colour detection.
  final centerX = frame.width ~/ 2;
  final centerY = frame.height ~/ 2;
  final sampleRadius = frame.width ~/ 4;

  int skinPixelCount = 0;
  int totalPixels = 0;
  double sumX = 0;
  double sumY = 0;

  // YUV420 skin-colour thresholds — works poorly for very dark or very
  // light skin under extreme lighting.  A real model would not have
  // this limitation.
  for (int dy = -sampleRadius; dy < sampleRadius; dy += 4) {
    for (int dx = -sampleRadius; dx < sampleRadius; dx += 4) {
      final px = centerX + dx;
      final py = centerY + dy;
      if (px < 0 || px >= frame.width || py < 0 || py >= frame.height) continue;

      final yIdx = py * frame.width + px;
      if (yIdx >= yPlane.length) continue;

      final y = yPlane[yIdx];
      int u = 128, v = 128;
      if (uPlane != null && vPlane != null) {
        final uvIdx = (py ~/ 2) * (frame.width ~/ 2) + (px ~/ 2);
        if (uvIdx < uPlane.length && uvIdx < vPlane.length) {
          u = uPlane[uvIdx];
          v = vPlane[uvIdx];
        }
      }

      final isSkin = y > 80 && y < 240 &&
          u > 85 && u < 135 &&
          v > 130 && v < 175;

      totalPixels++;
      if (isSkin) {
        skinPixelCount++;
        sumX += px;
        sumY += py;
      }
    }
  }

  if (totalPixels == 0) return const _DetectionResult(
    handDetected: false, landmarks: [], matchStrength: 0.0,
  );

  final skinRatio = skinPixelCount / totalPixels;
  final handDetected = skinRatio > 0.05;

  if (!handDetected) return const _DetectionResult(
    handDetected: false, landmarks: [], matchStrength: 0.0,
  );

  // Generate estimated landmarks from skin centroid.
  // These are fixed-offset approximations — NOT real detected joint positions.
  // Replace with actual model output for production use.
  final centroidX = skinPixelCount > 0 ? sumX / skinPixelCount : centerX.toDouble();
  final centroidY = skinPixelCount > 0 ? sumY / skinPixelCount : centerY.toDouble();
  final handSize = sampleRadius * 0.6;

  final landmarks = _generateEstimatedLandmarks(centroidX, centroidY, handSize, frame.width, frame.height);

  return _DetectionResult(
    handDetected: true,
    landmarks: landmarks,
    matchStrength: skinRatio.clamp(0.0, 1.0),
  );
}

/// Generate estimated hand landmarks from skin centroid.
///
/// Places 21 points at fixed offsets relative to the centroid.  These
/// simulate the MediaPipe Hands landmark layout but carry NO real
/// positional information — every frame produces the same relative
/// geometry regardless of actual finger positions.
///
/// Replace this function with real model inference for production use.
List<HandLandmark> _generateEstimatedLandmarks(
    double cx, double cy, double size, int imgW, int imgH) {
  final nx = cx / imgW;
  final ny = cy / imgH;
  final ns = size / imgW;

  return [
    // 0: Wrist
    HandLandmark(x: nx, y: ny + ns * 0.3, z: 0),
    // 1-4: Thumb (CMC, MCP, IP, TIP)
    HandLandmark(x: nx - ns * 0.3, y: ny + ns * 0.2, z: 0),
    HandLandmark(x: nx - ns * 0.4, y: ny + ns * 0.1, z: 0),
    HandLandmark(x: nx - ns * 0.5, y: ny - ns * 0.05, z: 0),
    HandLandmark(x: nx - ns * 0.55, y: ny - ns * 0.15, z: 0),
    // 5-8: Index (MCP, PIP, DIP, TIP)
    HandLandmark(x: nx - ns * 0.15, y: ny + ns * 0.05, z: 0),
    HandLandmark(x: nx - ns * 0.15, y: ny - ns * 0.15, z: 0),
    HandLandmark(x: nx - ns * 0.15, y: ny - ns * 0.3, z: 0),
    HandLandmark(x: nx - ns * 0.15, y: ny - ns * 0.45, z: 0),
    // 9-12: Middle (MCP, PIP, DIP, TIP)
    HandLandmark(x: nx, y: ny + ns * 0.05, z: 0),
    HandLandmark(x: nx, y: ny - ns * 0.18, z: 0),
    HandLandmark(x: nx, y: ny - ns * 0.33, z: 0),
    HandLandmark(x: nx, y: ny - ns * 0.5, z: 0),
    // 13-16: Ring (MCP, PIP, DIP, TIP)
    HandLandmark(x: nx + ns * 0.15, y: ny + ns * 0.05, z: 0),
    HandLandmark(x: nx + ns * 0.15, y: ny - ns * 0.13, z: 0),
    HandLandmark(x: nx + ns * 0.15, y: ny - ns * 0.28, z: 0),
    HandLandmark(x: nx + ns * 0.15, y: ny - ns * 0.42, z: 0),
    // 17-20: Pinky (MCP, PIP, DIP, TIP)
    HandLandmark(x: nx + ns * 0.3, y: ny + ns * 0.1, z: 0),
    HandLandmark(x: nx + ns * 0.3, y: ny - ns * 0.05, z: 0),
    HandLandmark(x: nx + ns * 0.3, y: ny - ns * 0.18, z: 0),
    HandLandmark(x: nx + ns * 0.3, y: ny - ns * 0.3, z: 0),
  ];
}
