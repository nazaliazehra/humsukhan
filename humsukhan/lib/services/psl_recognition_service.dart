import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Experimental hand-shape recognition service.
///
/// **This is NOT a real sign language translator.** The current implementation
/// uses skin-colour thresholding in YUV space to detect the presence of a hand
/// in the camera frame, then generates geometrically estimated "landmarks"
/// from the skin-colour centroid. These estimated landmarks are fed into a
/// simple rule-based classifier that maps a handful of finger-count patterns
/// to approximate character labels.
///
/// ## Current limitations
///
/// - Hand detection is based on skin colour, not a trained model. It will
///   struggle with lighting variations, gloves, and diverse skin tones.
/// - The 21 "landmarks" are placed at fixed offsets from the skin centroid.
///   They do NOT represent actual finger positions.
/// - Gesture classification uses finger-count heuristics on those estimated
///   landmarks — it cannot distinguish signs that require precise joint
///   angles, motion, or context.
/// - Left/right hand discrimination is unreliable with the front camera
///   (which mirrors the image).
/// - Character labels are illustrative approximations, not validated PSL
///   signs.
///
/// ## Replacing with a real model
///
/// To swap in a real hand-landmark model later, replace the
/// [_detectAndClassify] isolate function with one that runs a hand-landmark
/// neural network (e.g. MediaPipe Hands via TFLite). The downstream
/// [_classifyGesture] method already consumes [HandLandmark] lists in the
/// same 21-point format that MediaPipe Hands produces, so the classifier
/// can remain unchanged if the new model outputs compatible landmarks.
class PslRecognitionService {
  PslRecognitionService._();
  static PslRecognitionService? _instance;
  static PslRecognitionService get instance => _instance ??= PslRecognitionService._();

  CameraController? _cameraController;
  StreamSubscription? _frameSubscription;
  final StreamController<PslResult> _resultController =
      StreamController<PslResult>.broadcast();

  bool _isInitialized = false;
  bool _isProcessing = false;
  String _accumulatedText = '';
  DateTime? _lastSignTime;
  DateTime? _lastSpaceTime;

  static const Duration _signDebounce = Duration(milliseconds: 800);
  static const Duration _spaceTimeout = Duration(seconds: 2);

  Stream<PslResult> get onResult => _resultController.stream;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  String get accumulatedText => _accumulatedText;
  CameraController? get cameraController => _cameraController;

  /// Initialize camera for hand-shape detection.
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('HandShape: No cameras available');
        return false;
      }

      // Use front camera for selfie-style hand display.
      // NOTE: front camera mirrors the image horizontally, which flips
      // left/right hand assumptions. See _classifyGesture for details.
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
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

      debugPrint('HandShape: Camera initialized (${camera.name})');
      return true;
    } catch (e) {
      debugPrint('HandShape initialization error: $e');
      return false;
    }
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

    debugPrint('HandShape: Processing started');
  }

  /// Stop processing.
  void stopProcessing() {
    _isProcessing = false;
    _frameSubscription?.cancel();
    _cameraController?.stopImageStream();
    debugPrint('HandShape: Processing stopped');
  }

  /// Process a camera frame for hand detection and gesture classification.
  void _processFrame(CameraImage image) {
    if (_isProcessing) {
      _isProcessing = false; // Prevent re-entry

      compute(_detectAndClassify, _FrameData(
        planes: image.planes.map((p) => _PlaneData(
          bytes: p.bytes,
          bytesPerRow: p.bytesPerRow,
          bytesPerPixel: p.bytesPerPixel ?? 1,
        )).toList(),
        width: image.width,
        height: image.height,
        format: image.format.raw,
      )).then((result) {
        if (result != null) {
          _handleDetectionResult(result);
        }
        _isProcessing = true;
      }).catchError((e) {
        _isProcessing = true;
      });
    }
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

  /// Classify estimated hand landmarks into a gesture label.
  ///
  /// The classification is based on simple finger-count heuristics: it
  /// checks how many "finger tips" appear above their "PIP joints" in the
  /// estimated landmark set. Because the landmarks are geometrically placed
  /// (not detected by a model), the finger-extension signal is unreliable.
  ///
  /// **Handedness caveat:** The front camera mirrors the image. A right
  /// hand appears on the left side of the frame and vice versa. The thumb
  /// heuristic below uses an absolute x-axis comparison, which means it
  /// works for one hand orientation only. This is a known limitation of
  /// the heuristic approach.
  ///
  /// Returns null if no pattern matches.
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

    // A finger is "extended" if its tip is above (lower y value) its PIP
    // joint in the estimated landmark set.
    final indexExtended = indexTip.y < indexPip.y;
    final middleExtended = middleTip.y < middlePip.y;
    final ringExtended = ringTip.y < ringPip.y;
    final pinkyExtended = pinkyTip.y < pinkyPip.y;

    // Thumb: compare x-axis distance. With a mirrored front camera this
    // is ambiguous — it works for one hand but not the other. This is a
    // known limitation that only a real landmark model can resolve.
    final thumbExtended = (thumbTip.x - thumbIp.x).abs() > 0.02;

    // ── Hand-shape → character label mapping ────────────────────────────
    //
    // These labels are illustrative approximations used to demonstrate the
    // concept of hand-shape-to-text mapping. They are NOT validated PSL
    // finger-spelling signs and should not be relied upon for actual
    // sign-language communication.

    // All fingers closed
    if (!indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Fist', character: null);
    }

    // All fingers extended
    if (indexExtended && middleExtended && ringExtended && pinkyExtended) {
      if (thumbExtended) {
        return _PslGesture(name: 'Open Palm', isSpace: true);
      }
      return _PslGesture(name: 'Flat Hand', character: 'B');
    }

    // Index only
    if (indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Index Point', character: 'A');
    }

    // Index + middle (V shape)
    if (indexExtended && middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'V Shape', character: 'V');
    }

    // Three fingers up
    if (indexExtended && middleExtended && ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Three Fingers', character: 'W');
    }

    // Thumb only
    if (thumbExtended && !indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'Thumb', character: 'T');
    }

    // Thumb + index (L shape)
    if (thumbExtended && indexExtended && !middleExtended && !ringExtended && !pinkyExtended) {
      return _PslGesture(name: 'L Shape', character: 'L');
    }

    // Thumb + pinky (Y shape)
    if (thumbExtended && !indexExtended && !middleExtended && !ringExtended && pinkyExtended) {
      return _PslGesture(name: 'Y Shape', character: 'Y');
    }

    // Pinky only
    if (!indexExtended && !middleExtended && !ringExtended && pinkyExtended) {
      return _PslGesture(name: 'Pinky', character: 'I');
    }

    // Ring + pinky
    if (!indexExtended && !middleExtended && ringExtended && pinkyExtended) {
      return _PslGesture(name: 'Two Fingers', character: 'U');
    }

    // Middle only
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

  /// Reset and dispose.
  void dispose() {
    stopProcessing();
    _cameraController?.dispose();
    _cameraController = null;
    _isInitialized = false;
    _resultController.close();
  }
}

/// A single hand landmark point.
///
/// In the current heuristic prototype these are geometrically estimated
/// from the skin-colour centroid, not detected by a neural network.
/// When a real model is integrated, these will contain actual detected
/// coordinates.
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
/// confident a classification model is. Do not display this as a
/// "confidence" or "accuracy" percentage to the user.
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

/// Data passed to compute isolate for frame processing.
class _FrameData {
  final List<_PlaneData> planes;
  final int width;
  final int height;
  final int format;

  const _FrameData({
    required this.planes,
    required this.width,
    required this.height,
    required this.format,
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

/// Process a camera frame in an isolate using skin-colour thresholding.
///
/// This is a heuristic prototype. To integrate a real hand-landmark model,
/// replace this function with one that runs MediaPipe Hands (or another
/// TFLite hand-landmark model) on the frame bytes. The output must produce
/// a list of 21 [HandLandmark] points in the same order as the MediaPipe
/// Hands schema so that [_classifyGesture] can consume them unchanged.
_DetectionResult? _detectAndClassify(_FrameData frame) {
  if (frame.planes.isEmpty) return null;

  final yPlane = frame.planes[0].bytes;
  final uPlane = frame.planes.length > 1 ? frame.planes[1].bytes : null;
  final vPlane = frame.planes.length > 2 ? frame.planes[2].bytes : null;

  // Sample center region for skin colour detection
  final centerX = frame.width ~/ 2;
  final centerY = frame.height ~/ 2;
  final sampleRadius = frame.width ~/ 4;

  int skinPixelCount = 0;
  int totalPixels = 0;
  double sumX = 0;
  double sumY = 0;

  // YUV420 skin-colour thresholds.
  // This is a rough model that works poorly for very dark or very light
  // skin under extreme lighting — a known limitation.
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
  // These are fixed-offset approximations, NOT real detected joint
  // positions. Replace with actual model output for production use.
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
/// Places 21 points at fixed offsets relative to the centroid. These
/// simulate the MediaPipe Hands landmark layout so that [_classifyGesture]
/// can consume them, but they carry NO real positional information — every
/// frame produces the same relative geometry regardless of actual finger
/// positions.
///
/// Replace this function with real model inference for production use.
List<HandLandmark> _generateEstimatedLandmarks(
    double cx, double cy, double size, int imgW, int imgH) {
  final nx = cx / imgW;
  final ny = cy / imgH;
  final ns = size / imgW;

  // 21 points mimicking the MediaPipe Hands landmark order:
  // wrist, thumb(4), index(4), middle(4), ring(4), pinky(4).
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
