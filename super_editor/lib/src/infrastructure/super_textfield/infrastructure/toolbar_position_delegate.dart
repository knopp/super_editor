import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';

final _log = textFieldLog;

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

    _log.finer('ToolbarPositionDelegate:');
    _log.finer(' - available space: $size');
    _log.finer(' - child size: $childSize');
    _log.finer(' - text field offset: $textFieldGlobalOffset');
    _log.finer(' - ideal y-position: ${textFieldGlobalOffset.dy + desiredTopAnchorInTextField.dy}');
    _log.finer(' - fits above text field: $fitsAboveTextField');
    _log.finer(' - desired anchor: $desiredAnchor');
    _log.finer(' - desired top left: $desiredTopLeft');
    _log.finer(' - actual offset: $constrainedOffset');

    return constrainedOffset;
  }

  @override
  bool shouldRelayout(covariant SingleChildLayoutDelegate oldDelegate) {
    return true;
  }
}
