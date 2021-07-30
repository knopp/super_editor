import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';

/// A [SingleChildLayoutDelegate] that prevents its child from exceeding
/// the screen boundaries.
// TODO: offer optional padding from screen edges
class ToolbarPositionDelegate extends SingleChildLayoutDelegate {
  ToolbarPositionDelegate({
    required this.textFieldGlobalOffset,
    required this.desiredTopAnchorInTextField,
    required this.desiredBottomAnchorInTextField,
  });

  final Offset textFieldGlobalOffset;
  final Offset desiredTopAnchorInTextField;
  final Offset desiredBottomAnchorInTextField;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final fitsAboveTextField = (textFieldGlobalOffset.dy + desiredTopAnchorInTextField.dy) > 100;
    final desiredAnchor = fitsAboveTextField
        ? desiredTopAnchorInTextField
        : (desiredBottomAnchorInTextField + Offset(0, childSize.height));

    final desiredTopLeft = desiredAnchor - Offset(childSize.width / 2, childSize.height);

    double x = max(desiredTopLeft.dx, -textFieldGlobalOffset.dx);
    x = min(x, size.width - childSize.width - textFieldGlobalOffset.dx);

    final constrainedOffset = Offset(x, desiredTopLeft.dy);

    // print('ToolbarPositionDelegate:');
    // print(' - available space: $size');
    // print(' - child size: $childSize');
    // print(' - text field offset: $textFieldGlobalOffset');
    // print(' - ideal y-position: ${textFieldGlobalOffset.dy + desiredTopAnchorInTextField.dy}');
    // print(' - fits above text field: $fitsAboveTextField');
    // print(' - desired anchor: $desiredAnchor');
    // print(' - desired top left: $desiredTopLeft');
    // print(' - actual offset: $constrainedOffset');

    return constrainedOffset;
  }

  @override
  bool shouldRelayout(covariant SingleChildLayoutDelegate oldDelegate) {
    return true;
  }
}
