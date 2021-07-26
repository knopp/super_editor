import 'dart:ui';

import 'package:flutter/material.dart';

/// An area that displays a magnifying glass when the user drags.
///
/// [MagnifiedArea] looks for any drag event within its bounds.
/// When the user drags, a magnifying glass is displayed above
/// the user's finger, that magnifies the content where the user
/// is dragging.
class MagnifiedArea extends StatefulWidget {
  const MagnifiedArea({
    Key? key,
    required this.child,
  }) : super(key: key);

  final Widget child;

  @override
  _MagnifiedAreaState createState() => _MagnifiedAreaState();
}

class _MagnifiedAreaState extends State<MagnifiedArea> {
  final _magnifierDiameter = 72.0;
  final _aboveFingerGap = 72.0;
  final _magnifierScale = 3.0;

  Offset? _dragOffsetLocal;

  final _layerLink = LayerLink();

  OverlayEntry? _magnifierOverlay;

  void _onPanStart(DragStartDetails details) {
    setState(() {
      _dragOffsetLocal = details.localPosition;
    });

    _magnifierOverlay = OverlayEntry(builder: (context) {
      // The `Center` only exists to loosen the constraints on the
      // `FollowingMagnifier`. We want the magnifier to be whatever
      // size it wants.
      return Center(
        child: FollowingMagnifier(
          layerLink: _layerLink,
          aboveFingerGap: _aboveFingerGap,
          magnifierDiameter: _magnifierDiameter,
          magnifierScale: _magnifierScale,
        ),
      );
    });

    Overlay.of(context)!.insert(_magnifierOverlay!);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffsetLocal = details.localPosition;
    });

    _updateMagnifier(details.localPosition, details);
  }

  void _updateMagnifier(Offset localTouchOffset, DragUpdateDetails details) {
    _magnifierOverlay!.markNeedsBuild();
  }

  void _onPanEnd(DragEndDetails details) {
    _stopDragging();
  }

  void _onPanCancel() {
    _stopDragging();
  }

  void _stopDragging() {
    setState(() {
      _dragOffsetLocal = null;
    });

    _magnifierOverlay!.remove();
    _magnifierOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.green),
      ),
      child: GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: _onPanCancel,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            if (_dragOffsetLocal != null) ...[
              Positioned(
                left: _dragOffsetLocal!.dx,
                top: _dragOffsetLocal!.dy,
                child: CompositedTransformTarget(
                  link: _layerLink,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, -0.5),
                    child: Container(
                      width: 2,
                      height: 2,
                      color: Colors.blue,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A magnifying glass that follows a [LayerLink].
class FollowingMagnifier extends StatelessWidget {
  const FollowingMagnifier({
    Key? key,
    required this.layerLink,
    required this.aboveFingerGap,
    required this.magnifierDiameter,
    required this.magnifierScale,
  }) : super(key: key);

  final LayerLink layerLink;
  final double aboveFingerGap;
  final double magnifierDiameter;
  final double magnifierScale;

  @override
  Widget build(BuildContext context) {
    final magnifierOffsetFromFocalPoint = Offset(0.0, -aboveFingerGap);

    return CompositedTransformFollower(
      link: layerLink,
      offset: magnifierOffsetFromFocalPoint,
      child: Transform.translate(
        offset: Offset(-magnifierDiameter / 2, -magnifierDiameter / 2),
        child: CircleMagnifier(
          diameter: magnifierDiameter,
          offsetFromFocalPoint: magnifierOffsetFromFocalPoint,
          magnificationScale: magnifierScale,
        ),
      ),
    );
  }
}

/// A circular magnifying glass.
///
/// Magnifies the content beneath this [CircleMagnifier] at a level of
/// [magnificationScale] and displays that content in a circle with the
/// given [diameter].
///
/// By default, [CircleMagnifier] expects to be placed directly on top
/// of the content that it magnifies. Due to the way that magnification
/// works, if [CircleMagnifier] is displayed with an offset from the
/// content that it magnifies, that offset must be provided as
/// [offsetFromFocalPoint].
///
/// [CircleMagnifier] was designed to operate across the entire screen.
/// Using a [CircleMagnifier] in a confined region may result in the
/// magnifier mis-aligning the content that is magnifies.
class CircleMagnifier extends StatelessWidget {
  const CircleMagnifier({
    Key? key,
    this.offsetFromFocalPoint = Offset.zero,
    required this.diameter,
    required this.magnificationScale,
  }) : super(key: key);

  /// The offset from where the magnification is applied, to where this
  /// magnifier is displayed.
  ///
  /// An [offsetFromFocalPoint] of `Offset.zero` would indicate that this
  /// [CircleMagnifier] is displayed directly over the point of magnification.
  final Offset offsetFromFocalPoint;

  /// The diameter of this [CircleMagnifier].
  final double diameter;

  /// The level of magnification applied to the content beneath this
  /// [CircleMagnifier], expressed as a multiple of the natural dimensions.
  final double magnificationScale;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey, width: 2),
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: _createMagnificationFilter(),
          child: SizedBox(
            width: diameter,
            height: diameter,
          ),
        ),
      ),
    );
  }

  ImageFilter _createMagnificationFilter() {
    final magnifierMatrix = Matrix4.identity()
      ..translate(offsetFromFocalPoint.dx * magnificationScale, offsetFromFocalPoint.dy * magnificationScale)
      ..scale(magnificationScale, magnificationScale);

    return ImageFilter.matrix(magnifierMatrix.storage);
  }
}
