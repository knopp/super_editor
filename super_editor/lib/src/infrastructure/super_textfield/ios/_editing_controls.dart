import 'dart:math';

import 'package:flutter/material.dart';
import 'package:super_editor/src/infrastructure/super_selectable_text.dart';

import '_handles.dart';
import '_magnifier.dart';
import '_toolbar.dart';
import '_user_interaction.dart';

// TODO: idea - EditingOverlayController
// - showMagnifier
// - hideMagnifier
// - showToolbar
// - hideToolbar
// - showHandlesWhenSelectionExpanded
// - hideHandles

/// Editing controls for an iOS-style text field.
///
/// [IOSEditingControls] is intended to be displayed in the app's
/// [Overlay] so that its controls appear on top of everything else
/// in the app.
///
/// When [showToolbar] is true, displays an iOS-style toolbar with
/// buttons for various action like cut, copy, paste, etc.
///
/// When [showMagnifier] is true, displays an iOS-style magnifying
/// glass that magnifies the content beneath the user's finger.
///
/// When [selection] is expanded, displays iOS-style selection handles
/// on either side of the selection. When the user drags either of the
/// selection handles, [onBaseHandleDragStart], [onExtentHandleDragStart],
/// [onPanUpdate], [onPanEnd], and [onPanCancel] are invoked, respectively.
class IOSEditingControls extends StatefulWidget {
  const IOSEditingControls({
    Key? key,
    required this.textFieldViewportKey,
    required this.selectableTextKey,
    required this.textFieldLayerLink,
    required this.textContentOffsetLink,
    required this.interactorKey,
    required this.selection,
    required this.showToolbar,
    required this.showMagnifier,
    required this.handleDragMode,
    this.draggingHandleLink,
    required this.handleColor,
    this.showDebugPaint = false,
    required this.onBaseHandleDragStart,
    required this.onExtentHandleDragStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
  }) : super(key: key);

  /// [GlobalKey] that references to the text field's viewport.
  final GlobalKey textFieldViewportKey;

  /// [LayerLink] that is anchored to the text field's boundary.
  final LayerLink textFieldLayerLink;

  /// [LayerLink] that is anchored to the (possibly scrolling) content
  /// within the text field.
  final LayerLink textContentOffsetLink;

  /// [GlobalKey] that references the [SuperSelectableTextState] within
  /// the text field.
  final GlobalKey<SuperSelectableTextState> selectableTextKey;

  /// [GlobalKey] that references the [IOSTextFieldInteractorState] within
  /// the text field.
  final GlobalKey<IOSTextfieldInteractorState> interactorKey;

  /// The current text selection within the text field.
  final TextSelection selection;

  /// Whether to display the toolbar with actions like cut, copy, paste, etc.
  final bool showToolbar;

  /// Whether to show the magnifier that magnifies the content near
  /// [draggingHandleLink].
  final bool showMagnifier;

  /// The type of handle that is currently being dragged.
  final HandleDragMode? handleDragMode;

  /// [LayerLink] that is anchored to the handle that is currently being dragged.
  final LayerLink? draggingHandleLink;

  /// The color of the selection handles.
  final Color handleColor;

  /// Whether to paint debug guides.
  final bool showDebugPaint;

  /// Callback invoked when the user starts to drag the base selection handle.
  final Function(DragStartDetails details) onBaseHandleDragStart;

  /// Callback invoked when the user starts to drag the extent selection handle.
  final Function(DragStartDetails details) onExtentHandleDragStart;

  /// Callback invoked when the user drags either the base or extent handle.
  final Function(DragUpdateDetails details) onPanUpdate;

  /// Callback invoked when the user stops dragging either the base or extent handle.
  final Function(DragEndDetails details) onPanEnd;

  /// Callback invoked when a base or extend handle drag is cancelled.
  final VoidCallback onPanCancel;

  @override
  _IOSEditingControlsState createState() => _IOSEditingControlsState();
}

class _IOSEditingControlsState extends State<IOSEditingControls> {
  // These global keys are assigned to each draggable handle to
  // prevent a strange dragging issue.
  //
  // Without these keys, if the user drags into the auto-scroll area
  // of the text field for a period of time, we never receive a
  // "pan end" or "pan cancel" callback. I have no idea why this is
  // the case. These handles sit in an Overlay, so it's not as if they
  // suffered some conflict within a ScrollView. I tried many adjustments
  // to recover the end/cancel callbacks. Finally, I tried adding these
  // global keys based on a hunch that perhaps the gesture detector was
  // somehow getting switched out, or assigned to a different widget, and
  // that was somehow disrupting the callback series. For now, these keys
  // seem to solve the problem.
  final _upstreamHandleKey = GlobalKey();
  final _downstreamHandleKey = GlobalKey();

  bool _isDraggingBase = false;
  bool _isDraggingExtent = false;

  void _onBasePanStart(DragStartDetails details) {
    print('_onBasePanStart');
    _isDraggingBase = true;
    _isDraggingExtent = false;
    widget.onBaseHandleDragStart(details);
  }

  void _onExtentPanStart(DragStartDetails details) {
    print('_onExtentPanStart');
    _isDraggingBase = false;
    _isDraggingExtent = true;
    widget.onExtentHandleDragStart(details);
  }

  void _onPanEnd(DragEndDetails details) {
    print('_onPanEnd');
    _isDraggingBase = false;
    _isDraggingExtent = false;
    widget.onPanEnd(details);
  }

  void _onPanCancel() {
    print('_onPanCancel');
    _isDraggingBase = false;
    _isDraggingExtent = false;
    widget.onPanCancel();
  }

  @override
  Widget build(BuildContext context) {
    final textFieldRenderObject = context.findRenderObject();
    if (textFieldRenderObject == null) {
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        setState(() {});
      });
      return const SizedBox();
    }

    return Stack(
      children: [
        ..._buildDraggableOverlayHandles(),
        _buildToolbar(),
        if (widget.showMagnifier)
          Center(
            child: FollowingMagnifier(
              layerLink: widget.draggingHandleLink!,
              aboveFingerGap: 72,
              magnifierDiameter: 72,
              magnifierScale: 2,
            ),
          )
      ],
    );
  }

  Widget _buildToolbar() {
    if (widget.selection.extentOffset < 0) {
      return const SizedBox();
    }

    const toolbarGap = 24.0;
    Offset toolbarTopAnchor;
    Offset toolbarBottomAnchor;

    if (widget.selection.isCollapsed) {
      final extentOffsetInText = widget.selectableTextKey.currentState!.getOffsetAtPosition(widget.selection.extent);
      final extentOffsetInViewport = widget.interactorKey.currentState!.textOffsetToViewportOffset(extentOffsetInText);
      final lineHeight = widget.selectableTextKey.currentState!.getLineHeightAtPosition(widget.selection.extent);

      toolbarTopAnchor = extentOffsetInViewport - const Offset(0, toolbarGap);
      toolbarBottomAnchor = extentOffsetInViewport + Offset(0, lineHeight) + const Offset(0, toolbarGap);
      print('Collapsed top anchor offset in viewport: $toolbarTopAnchor');
    } else {
      final selectionBoxes = widget.selectableTextKey.currentState!.getBoxesForSelection(widget.selection);
      Rect selectionBounds = selectionBoxes.first.toRect();
      for (int i = 1; i < selectionBoxes.length; ++i) {
        selectionBounds = selectionBounds.expandToInclude(selectionBoxes[i].toRect());
      }
      final selectionTopInText = selectionBounds.topCenter;
      final selectionTopInViewport = widget.interactorKey.currentState!.textOffsetToViewportOffset(selectionTopInText);
      toolbarTopAnchor = selectionTopInViewport - const Offset(0, toolbarGap);

      final selectionBottomInText = selectionBounds.bottomCenter;
      final selectionBottomInViewport =
          widget.interactorKey.currentState!.textOffsetToViewportOffset(selectionBottomInText);
      toolbarBottomAnchor = selectionBottomInViewport + const Offset(0, toolbarGap);
    }

    // The selection might start above the visible area in a scrollable
    // text field. In that case, we don't want the toolbar to sit more
    // than [toolbarGap] above the text field.
    toolbarTopAnchor = Offset(
      toolbarTopAnchor.dx,
      max(
        toolbarTopAnchor.dy,
        -toolbarGap,
      ),
    );

    // The selection might end below the visible area in a scrollable
    // text field. In that case, we don't want the toolbar to sit more
    // than [toolbarGap] below the text field.
    final viewportHeight = (widget.textFieldViewportKey.currentContext!.findRenderObject() as RenderBox).size.height;
    toolbarTopAnchor = Offset(
      toolbarTopAnchor.dx,
      min(
        toolbarTopAnchor.dy,
        viewportHeight + toolbarGap,
      ),
    );

    print('Adjusted top anchor: $toolbarTopAnchor');

    final textFieldGlobalOffset =
        (widget.textFieldViewportKey.currentContext!.findRenderObject() as RenderBox).localToGlobal(Offset.zero);

    return Stack(
      children: [
        // TODO: figure out why this approach works. Why isn't the text field's
        //       RenderBox offset stale when the keyboard opens or closes? Shouldn't
        //       we end up with the previous offset because no rebuild happens?
        //
        //       Dis-proven theory: CompositedTransformFollower's link causes a rebuild of its
        //       subtree whenever the linked transform changes.
        //
        //       Theory:
        //         - Keyboard only effects vertical offsets, so global x offset
        //           was never at risk
        //         - The global y offset isn't used in the calculation at all
        //         - If this same approach were used in a situation where the
        //           distance between the left edge of the available space and the
        //           text field changed, I think it would fail.
        CompositedTransformFollower(
          link: widget.textFieldLayerLink,
          child: CustomSingleChildLayout(
            delegate: ToolbarPositionDelegate(
              textFieldGlobalOffset: textFieldGlobalOffset,
              desiredTopAnchorInTextField: toolbarTopAnchor,
              desiredBottomAnchorInTextField: toolbarBottomAnchor,
            ),
            child: IgnorePointer(
              ignoring: !widget.showToolbar,
              child: AnimatedOpacity(
                opacity: widget.showToolbar ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: IOSTextfieldToolbar(
                  onCutPressed: () {},
                  onCopyPressed: () {},
                  onPastePressed: () {},
                  onSharePressed: () {},
                  onLookUpPressed: () {},
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildDraggableOverlayHandles() {
    if (widget.selection.extentOffset < 0) {
      print('No extent -> no drag handles');
      // There is no selection. Draw nothing.
      return [];
    }

    if (widget.selection.isCollapsed &&
        widget.handleDragMode != HandleDragMode.base &&
        widget.handleDragMode != HandleDragMode.extent) {
      print('No handle drag mode -> no drag handles');
      // iOS does not display a drag handle when the selection is collapsed.
      return [];
    }

    // The selection is expanded. Draw 2 drag handles.
    final baseCaretOffsetInSelectableText =
        widget.selectableTextKey.currentState!.getOffsetAtPosition(widget.selection.base);
    final baseCaretGlobalOffset = (widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox)
        .localToGlobal(baseCaretOffsetInSelectableText);
    final baseCaretOffsetInViewport = (widget.textFieldViewportKey.currentContext!.findRenderObject() as RenderBox)
        .globalToLocal(baseCaretGlobalOffset);
    final baseLineHeight = widget.selectableTextKey.currentState!.getLineHeightAtPosition(widget.selection.base);

    final extentCaretOffsetInSelectableText =
        widget.selectableTextKey.currentState!.getOffsetAtPosition(widget.selection.extent);
    final extentCaretGlobalOffset = (widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox)
        .localToGlobal(extentCaretOffsetInSelectableText);
    final extentCaretOffsetInViewport = (widget.textFieldViewportKey.currentContext!.findRenderObject() as RenderBox)
        .globalToLocal(extentCaretGlobalOffset);
    final extentLineHeight = widget.selectableTextKey.currentState!.getLineHeightAtPosition(widget.selection.extent);

    if (baseLineHeight == 0 || extentLineHeight == 0) {
      print('No height info -> no drag handles');
      // A line height of zero indicates that the text isn't laid out yet.
      // Schedule a rebuild to give the text a frame to layout.
      _scheduleRebuildBecauseTextIsNotLaidOutYet();
      return [];
    }

    // TODO: handle the case with no text affinity and then query widget.selection!.affinity
    final selectionDirection =
        widget.selection.extentOffset >= widget.selection.baseOffset ? TextAffinity.downstream : TextAffinity.upstream;

    // TODO: handle RTL text orientation
    final upstreamCaretOffset =
        selectionDirection == TextAffinity.downstream ? baseCaretOffsetInViewport : extentCaretOffsetInViewport;

    final downstreamCaretOffset =
        selectionDirection == TextAffinity.downstream ? extentCaretOffsetInViewport : baseCaretOffsetInViewport;

    // TODO: the following behavior checks if the handle visually overlaps
    //       the visible text box at all, and then hides the handle if it
    //       doesn't. Change this logic to instead get the bounding box around
    //       the first character in the selection and see if that character is
    //       at least partially visible. We should do this because at the moment
    //       the handle shows itself when its an entire line above or below the
    //       visible area.
    bool showBaseHandle = false;
    bool showExtentHandle = false;
    if (widget.textContentOffsetLink.leader != null) {
      final textFieldBox = widget.textFieldViewportKey.currentContext!.findRenderObject() as RenderBox;
      final textFieldRect = Offset.zero & textFieldBox.size;

      const estimatedHandleVisualSize = Size(24, 24);

      final estimatedBaseHandleRect = upstreamCaretOffset & estimatedHandleVisualSize;

      final estimatedExtentHandleRect = downstreamCaretOffset & estimatedHandleVisualSize;

      showBaseHandle = _isDraggingBase ||
          widget.handleDragMode == HandleDragMode.base ||
          textFieldRect.overlaps(estimatedBaseHandleRect);
      showExtentHandle = _isDraggingExtent ||
          widget.handleDragMode == HandleDragMode.extent ||
          textFieldRect.overlaps(estimatedExtentHandleRect);
    }

    if (!showExtentHandle) {
      print('Hiding extent handle');
    }

    return [
      if (showBaseHandle) ...[
        // Left-bounding handle touch target
        CompositedTransformFollower(
          key: _upstreamHandleKey,
          link: widget.textContentOffsetLink,
          offset: Offset(upstreamCaretOffset.dx, upstreamCaretOffset.dy),
          child: Transform.translate(
            offset: const Offset(-12, -5),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: selectionDirection == TextAffinity.downstream ? _onBasePanStart : _onExtentPanStart,
              onPanUpdate: widget.onPanUpdate,
              onPanEnd: _onPanEnd,
              onPanCancel: _onPanCancel,
              child: Container(
                width: 24,
                color: widget.showDebugPaint ? Colors.green : Colors.transparent,
                child: IOSTextFieldHandle.upstream(
                  color: widget.handleColor,
                  caretHeight: baseLineHeight,
                ),
              ),
            ),
          ),
        ),
      ],
      if (showExtentHandle) ...[
        // Left-bounding handle touch target
        CompositedTransformFollower(
          key: _downstreamHandleKey,
          link: widget.textContentOffsetLink,
          offset: Offset(downstreamCaretOffset.dx, downstreamCaretOffset.dy),
          child: Transform.translate(
            offset: const Offset(-12, -5),
            child: GestureDetector(
              onPanStart: selectionDirection == TextAffinity.downstream ? _onExtentPanStart : _onBasePanStart,
              onPanUpdate: widget.onPanUpdate,
              onPanEnd: _onPanEnd,
              onPanCancel: _onPanCancel,
              child: Container(
                width: 24,
                color: widget.showDebugPaint ? Colors.red : Colors.transparent,
                child: IOSTextFieldHandle.downstream(
                  color: widget.handleColor,
                  caretHeight: extentLineHeight,
                ),
              ),
            ),
          ),
        ),
      ],
    ];
  }

  void _scheduleRebuildBecauseTextIsNotLaidOutYet() {
    WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
      if (mounted) {
        setState(() {
          // no-op. Rebuild this widget in the hopes that the selectable
          // text has gone through a layout pass.
        });
      }
    });
  }
}

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
