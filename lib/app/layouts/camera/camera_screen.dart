import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';
import 'package:video_player/video_player.dart';

/// Full-screen in-app camera screen backed by the CameraX API (Android) via
/// the `camera` Flutter plugin. Supports both photo and video modes.
///
/// Returns the captured [XFile] via [Navigator.pop], or `null` if the user
/// cancels. Only rendered on Android; callers should guard with
/// `Platform.isAndroid && !kIsWeb` before pushing this route.
class CameraScreen extends StatefulWidget {
  /// 'photo' (default) or 'video'.
  final String initialMode;

  const CameraScreen({super.key, this.initialMode = 'photo'});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _cameraIndex = 0;

  late String _mode; // 'photo' or 'video'
  bool _isRecording = false;
  bool _isInitializing = true;
  String? _initError;

  FlashMode _flashMode = FlashMode.auto;

  // Preview (after capture, before confirm)
  XFile? _previewFile;

  // Video timer
  Timer? _timer;
  int _recordingSeconds = 0;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initControllerAt(_cameraIndex);
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _initError = 'No cameras found on this device.';
          _isInitializing = false;
        });
        return;
      }
      // Prefer back camera as default
      final backIndex = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _cameraIndex = backIndex >= 0 ? backIndex : 0;
      await _initControllerAt(_cameraIndex);
    } catch (e) {
      setState(() {
        _initError = 'Failed to initialize camera: $e';
        _isInitializing = false;
      });
    }
  }

  Future<void> _initControllerAt(int index) async {
    final previous = _controller;
    if (previous != null) {
      await previous.dispose();
    }

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    _controller = controller;

    try {
      await controller.initialize();
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = null;
        });
        // Apply current flash mode after initialization
        await _applyFlashMode();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = 'Camera initialization failed: $e';
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _applyFlashMode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setFlashMode(_mode == 'video' && _flashMode == FlashMode.always ? FlashMode.torch : _flashMode);
    } catch (_) {
      // Not all devices support every flash mode — silently ignore.
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    if (_isRecording) return;
    setState(() => _isInitializing = true);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initControllerAt(_cameraIndex);
  }

  void _cycleFlash() {
    if (_mode == 'video') {
      // In video mode toggle torch on/off
      setState(() {
        _flashMode = _flashMode == FlashMode.torch ? FlashMode.off : FlashMode.torch;
      });
    } else {
      final order = [FlashMode.auto, FlashMode.always, FlashMode.off];
      final next = order[(order.indexOf(_flashMode) + 1) % order.length];
      setState(() => _flashMode = next);
    }
    _applyFlashMode();
  }

  IconData get _flashIcon {
    switch (_flashMode) {
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.torch:
        return Icons.flashlight_on;
      case FlashMode.auto:
        return Icons.flash_auto;
    }
  }

  // ─── Capture ─────────────────────────────────────────────────────────────

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture) return;

    try {
      final file = await controller.takePicture();
      if (mounted) setState(() => _previewFile = file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to take photo: $e')),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isRecordingVideo) return;

    try {
      await controller.startVideoRecording();
      setState(() {
        _isRecording = true;
        _recordingSeconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isRecordingVideo) return;

    _timer?.cancel();

    try {
      final file = await controller.stopVideoRecording();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _previewFile = file;
        });
      }
    } catch (e) {
      setState(() => _isRecording = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop recording: $e')),
        );
      }
    }
  }

  void _onShutterTap() {
    if (_mode == 'photo') {
      _takePhoto();
    } else {
      if (_isRecording) {
        _stopRecording();
      } else {
        _startRecording();
      }
    }
  }

  // ─── Timer display ────────────────────────────────────────────────────────

  String get _timerLabel {
    final m = (_recordingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recordingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Guard: only render on Android
    if (kIsWeb || !Platform.isAndroid) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _isInitializing
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _initError != null
                ? _buildError()
                : _previewFile != null
                    ? _buildPreview()
                    : _buildCamera(),
      ),
    );
  }

  Widget _buildPreview() {
    final file = _previewFile!;
    final isVideo = _mode == 'video';
    return Stack(
      fit: StackFit.expand,
      children: [
        // Full-screen preview
        Container(
          color: Colors.black,
          child: Center(
            child: isVideo ? _VideoPreview(file: file) : Image.file(File(file.path), fit: BoxFit.contain),
          ),
        ),

        // Close button
        Positioned(
          top: 8,
          right: 0,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            onPressed: () => Navigator.of(context).pop(null),
          ),
        ),

        // Retake / Use bar
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text('Retake', style: TextStyle(color: Colors.white, fontSize: 16)),
                  onPressed: () => setState(() => _previewFile = null),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.check_circle_outline, color: Colors.white),
                  label: const Text('Use', style: TextStyle(color: Colors.white, fontSize: 16)),
                  onPressed: () => Navigator.of(context).pop(file),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(_initError!, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Close', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCamera() {
    final controller = _controller!;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview — fills the screen respecting aspect ratio
        Center(
          child: _isRecording ? _withRecordingBorder(CameraPreview(controller)) : CameraPreview(controller),
        ),

        // Top bar: flash + close
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: _buildTopBar(),
        ),

        // Bottom controls
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _buildBottomControls(),
        ),

        // Recording timer
        if (_isRecording)
          Positioned(
            top: 56,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.circle, color: Colors.red, size: 10),
                    const SizedBox(width: 6),
                    Text(_timerLabel, style: const TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _withRecordingBorder(Widget child) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.red, width: 3),
      ),
      child: child,
    );
  }

  Widget _buildTopBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Flash toggle (hide during recording and on front camera)
        if (_mode == 'photo' || (_mode == 'video' && _cameras[_cameraIndex].lensDirection == CameraLensDirection.back))
          IconButton(
            icon: Icon(_flashIcon, color: Colors.white, size: 28),
            onPressed: _isRecording ? null : _cycleFlash,
          )
        else
          const SizedBox(width: 48),

        // Close button
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 28),
          onPressed: () async {
            if (_isRecording) await _controller?.stopVideoRecording();
            if (mounted) Navigator.of(context).pop(null);
          },
        ),
      ],
    );
  }

  Widget _buildBottomControls() {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mode selector
          _buildModeSelector(),
          const SizedBox(height: 24),
          // Shutter row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Camera flip
              IconButton(
                icon: const Icon(Icons.flip_camera_android, color: Colors.white, size: 32),
                onPressed: _isRecording ? null : _flipCamera,
              ),
              // Shutter / Record button
              _buildShutterButton(),
              // Placeholder for symmetry
              const SizedBox(width: 48),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ModeTab(
            label: 'PHOTO',
            selected: _mode == 'photo',
            onTap: _isRecording
                ? null
                : () {
                    setState(() => _mode = 'photo');
                    _applyFlashMode();
                  }),
        const SizedBox(width: 32),
        _ModeTab(
            label: 'VIDEO',
            selected: _mode == 'video',
            onTap: _isRecording
                ? null
                : () {
                    setState(() => _mode = 'video');
                    _applyFlashMode();
                  }),
      ],
    );
  }

  Widget _buildShutterButton() {
    final isVideo = _mode == 'video';
    final recording = _isRecording;

    return GestureDetector(
      onTap: _onShutterTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: recording ? 28 : (isVideo ? 52 : 60),
            height: recording ? 28 : (isVideo ? 52 : 60),
            decoration: BoxDecoration(
              color: isVideo ? Colors.red : Colors.white,
              shape: recording ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: recording ? BorderRadius.circular(6) : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoPreview extends StatefulWidget {
  final XFile file;

  const _VideoPreview({required this.file});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late VideoPlayerController _videoController;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _videoController = VideoPlayerController.file(File(widget.file.path));
    _videoController.initialize().then((_) {
      if (mounted) {
        setState(() => _initialized = true);
        _videoController.setLooping(true);
        _videoController.play();
      }
    });
  }

  @override
  void dispose() {
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_videoController.value.isPlaying) {
            _videoController.pause();
          } else {
            _videoController.play();
          }
        });
      },
      child: AspectRatio(
        aspectRatio: _videoController.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(_videoController),
            if (!_videoController.value.isPlaying)
              const Icon(Icons.play_circle_outline, color: Colors.white70, size: 72),
          ],
        ),
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _ModeTab({required this.label, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.yellow : Colors.white70,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          fontSize: 14,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
