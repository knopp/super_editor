import 'package:flutter/widgets.dart';
import 'package:super_editor/src/infrastructure/super_selectable_text.dart';
import 'package:super_editor/src/infrastructure/text_layout.dart';

class AndroidTextControlsFactory implements TextCaretFactory {
  AndroidTextControlsFactory({
    required Color color,
    BorderRadius borderRadius = BorderRadius.zero,
  })  : _color = color,
        _borderRadius = borderRadius;

  final Color _color;
  final BorderRadius _borderRadius;

  @override
  Widget build({
    required BuildContext context,
    required TextLayout textLayout,
    required TextSelection selection,
    required bool isTextEmpty,
    required bool showCaret,
  }) {
    return AndroidTextFieldCaret(
      textLayout: textLayout,
      isTextEmpty: isTextEmpty,
      selection: selection,
      caretColor: _color,
      caretBorderRadius: _borderRadius,
    );
  }
}

/// An Android-style blinking caret.
///
/// [AndroidTextFieldCaret] should be displayed on top of its corresponding
/// text, and it should be displayed at the same width and height as the
/// text. [AndroidTextFieldCaret] uses [textLayout] to calculate the
/// position of the caret from the top-left corner of the text and
/// then paints a blinking caret at that location.
class AndroidTextFieldCaret extends StatefulWidget {
  const AndroidTextFieldCaret({
    Key? key,
    required this.textLayout,
    required this.isTextEmpty,
    required this.selection,
    required this.caretColor,
    this.caretWidth = 2.0,
    this.caretBorderRadius = BorderRadius.zero,
  }) : super(key: key);

  final TextLayout textLayout;
  final bool isTextEmpty;
  final TextSelection selection;
  final Color caretColor;
  final double caretWidth;
  final BorderRadius caretBorderRadius;

  @override
  _AndroidTextFieldCaretState createState() => _AndroidTextFieldCaretState();
}

class _AndroidTextFieldCaretState extends State<AndroidTextFieldCaret> with SingleTickerProviderStateMixin {
  late CaretBlinkController _caretBlinkController;

  @override
  void initState() {
    super.initState();
    _caretBlinkController = CaretBlinkController(tickerProvider: this);
  }

  @override
  void didUpdateWidget(AndroidTextFieldCaret oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.selection != oldWidget.selection) {
      _caretBlinkController.caretPosition = widget.selection.isCollapsed ? widget.selection.extent : null;
    }
  }

  @override
  void dispose() {
    _caretBlinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: AndroidCursorPainter(
        blinkController: _caretBlinkController,
        textLayout: widget.textLayout,
        width: widget.caretWidth,
        borderRadius: widget.caretBorderRadius,
        selection: widget.selection,
        caretColor: widget.caretColor,
        isTextEmpty: widget.isTextEmpty,
      ),
    );
  }
}

class AndroidCursorPainter extends CustomPainter {
  AndroidCursorPainter({
    required this.blinkController,
    required this.textLayout,
    required this.width,
    required this.borderRadius,
    required this.selection,
    required this.caretColor,
    required this.isTextEmpty,
  })  : caretPaint = Paint()..color = caretColor,
        super(repaint: blinkController);

  final CaretBlinkController blinkController;
  final TextLayout textLayout;
  final TextSelection selection;
  final double width;
  final BorderRadius borderRadius;
  final bool isTextEmpty;
  final Color caretColor;
  final Paint caretPaint;

  @override
  void paint(Canvas canvas, Size size) {
    if (selection.extentOffset < 0) {
      return;
    }

    if (!selection.isCollapsed) {
      return;
    }

    if (blinkController.opacity == 0.0) {
      return;
    }

    _drawCaret(canvas: canvas);
  }

  void _drawCaret({
    required Canvas canvas,
  }) {
    caretPaint.color = caretColor.withOpacity(blinkController.opacity);

    final caretHeight = textLayout.getLineHeightAtPosition(selection.extent);

    Offset caretOffset = isTextEmpty ? Offset.zero : textLayout.getOffsetAtPosition(selection.extent);

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
        isTextEmpty != oldDelegate.isTextEmpty;
  }
}
