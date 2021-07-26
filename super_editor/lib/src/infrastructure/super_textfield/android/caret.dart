import 'package:flutter/widgets.dart';
import 'package:super_editor/src/infrastructure/super_selectable_text.dart';
import 'package:super_editor/src/infrastructure/text_layout.dart';

class AndroidCursorPainter extends CustomPainter {
  AndroidCursorPainter({
    required this.blinkController,
    required this.textLayout,
    required this.width,
    required this.borderRadius,
    required this.selection,
    required this.caretColor,
    required this.isTextEmpty,
    required this.showCaret,
    required this.showHandle,
  })  : caretPaint = Paint()..color = caretColor,
        handlePaint = Paint()..color = caretColor,
        super(repaint: blinkController);

  final CaretBlinkController blinkController;
  final TextLayout textLayout;
  final TextSelection selection;
  final double width;
  final BorderRadius borderRadius;
  final bool isTextEmpty;
  final bool showCaret;
  final bool showHandle;
  final Color caretColor;
  final Paint caretPaint;
  final Paint handlePaint;

  @override
  void paint(Canvas canvas, Size size) {
    if (!showCaret) {
      return;
    }

    if (selection.extentOffset < 0) {
      return;
    }

    if (selection.isCollapsed && showCaret) {
      _drawCaret(
        canvas: canvas,
        textPosition: selection.extent,
      );
    }
  }

  void _drawCaret({
    required Canvas canvas,
    required TextPosition textPosition,
  }) {
    caretPaint.color = caretColor.withOpacity(blinkController.opacity);

    final caretHeight = textLayout.getLineHeightAtPosition(textPosition);

    Offset caretOffset = isTextEmpty ? Offset.zero : textLayout.getOffsetAtPosition(textPosition);

    if (borderRadius == BorderRadius.zero) {
      canvas.drawRect(
        Rect.fromLTWH(
          caretOffset.dx.roundToDouble() - (width / 2),
          caretOffset.dy.roundToDouble(),
          width,
          caretHeight.roundToDouble(),
        ),
        caretPaint,
      );
    } else {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          caretOffset.dx.roundToDouble(),
          caretOffset.dy.roundToDouble(),
          caretOffset.dx.roundToDouble() + width,
          caretOffset.dy.roundToDouble() + caretHeight.roundToDouble(),
          topLeft: borderRadius.topLeft,
          topRight: borderRadius.topRight,
          bottomLeft: borderRadius.bottomLeft,
          bottomRight: borderRadius.bottomRight,
        ),
        caretPaint,
      );
    }
  }

  @override
  bool shouldRepaint(AndroidCursorPainter oldDelegate) {
    return textLayout != oldDelegate.textLayout ||
        selection != oldDelegate.selection ||
        isTextEmpty != oldDelegate.isTextEmpty ||
        showCaret != oldDelegate.showCaret;
  }
}
