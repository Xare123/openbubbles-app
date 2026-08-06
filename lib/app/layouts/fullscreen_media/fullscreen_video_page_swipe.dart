import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The physical direction of a swipe over a fullscreen video.
enum FullscreenVideoPageSwipeDirection {
  left,
  right,
}

/// Converts a physical swipe to the neighboring PageView index delta.
int fullscreenVideoPageDelta(
  FullscreenVideoPageSwipeDirection direction, {
  required bool reverse,
}) {
  final physicalForward = direction == FullscreenVideoPageSwipeDirection.left;
  return physicalForward == reverse ? -1 : 1;
}

/// Lets fullscreen videos participate in the surrounding media [PageView].
///
/// media_kit's mobile controls own a full-surface horizontal drag recognizer
/// for seeking. That recognizer wins Flutter's gesture arena before the parent
/// PageView can see the drag, even when seeking is disabled. A raw [Listener]
/// observes the same pointer sequence without competing in that arena, so
/// video controls and timeline scrubbing remain interactive while deliberate
/// swipes over the video can still request an adjacent media page.
class FullscreenVideoPageSwipeSurface extends StatefulWidget {
  const FullscreenVideoPageSwipeSurface({
    super.key,
    required this.child,
    required this.onPageSwipe,
    this.controlsExclusionHeight = 88,
    this.minimumDistance = 48,
    this.minimumFlingDistance = 18,
    this.minimumFlingVelocity = 500,
  });

  final Widget child;
  final ValueChanged<FullscreenVideoPageSwipeDirection>? onPageSwipe;

  /// Bottom area reserved for the seek bar and transport controls.
  final double controlsExclusionHeight;

  /// Distance needed for a normal swipe.
  final double minimumDistance;

  /// Minimum distance accepted for a fast fling.
  final double minimumFlingDistance;

  /// Horizontal logical pixels per second needed for a short fling.
  final double minimumFlingVelocity;

  @override
  State<FullscreenVideoPageSwipeSurface> createState() =>
      _FullscreenVideoPageSwipeSurfaceState();
}

class _FullscreenVideoPageSwipeSurfaceState
    extends State<FullscreenVideoPageSwipeSurface> {
  int? _pointer;
  Offset? _origin;
  Duration? _startedAt;
  bool _startedOverControls = false;

  void _reset() {
    _pointer = null;
    _origin = null;
    _startedAt = null;
    _startedOverControls = false;
  }

  void _onPointerDown(PointerDownEvent event, double height) {
    if (widget.onPageSwipe == null || _pointer != null) return;

    _pointer = event.pointer;
    _origin = event.localPosition;
    _startedAt = event.timeStamp;
    _startedOverControls = event.localPosition.dy >=
        math.max(0, height - widget.controlsExclusionHeight);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;

    final origin = _origin;
    final latest = event.localPosition;
    final startedAt = _startedAt;
    final callback = widget.onPageSwipe;
    final startedOverControls = _startedOverControls;
    _reset();

    if (origin == null ||
        startedAt == null ||
        callback == null ||
        startedOverControls) {
      return;
    }

    final delta = latest - origin;
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    if (horizontalDistance <= verticalDistance * 1.2) return;

    final elapsedMicros =
        math.max(1, (event.timeStamp - startedAt).inMicroseconds);
    final horizontalVelocity =
        horizontalDistance * Duration.microsecondsPerSecond / elapsedMicros;
    final isDistanceSwipe = horizontalDistance >= widget.minimumDistance;
    final isFling = horizontalDistance >= widget.minimumFlingDistance &&
        horizontalVelocity >= widget.minimumFlingVelocity;
    if (!isDistanceSwipe && !isFling) return;

    callback(
      delta.dx < 0
          ? FullscreenVideoPageSwipeDirection.left
          : FullscreenVideoPageSwipeDirection.right,
    );
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _reset();
  }

  @override
  void didUpdateWidget(covariant FullscreenVideoPageSwipeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onPageSwipe == null) _reset();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onPageSwipe == null) return widget.child;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) =>
              _onPointerDown(event, constraints.maxHeight),
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: widget.child,
        );
      },
    );
  }
}
