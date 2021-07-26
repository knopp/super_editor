import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:super_editor/src/infrastructure/attributed_text.dart';
import 'package:super_editor/src/infrastructure/multi_tap_gesture.dart';
import 'package:super_editor/src/infrastructure/super_selectable_text.dart';
import 'package:super_editor/src/infrastructure/text_layout.dart';

import 'caret.dart';
import 'handles.dart';
import 'toolbar.dart';

class AndroidTextfieldControls extends StatefulWidget {
  const AndroidTextfieldControls({
    Key? key,
    required this.focusNode,
    required this.textLayout,
    required this.selectableText,
    required this.text,
    required this.selection,
    required this.color,
    required this.width,
    required this.borderRadius,
    required this.showCaret,
    required this.onDragSelectionChanged,
  }) : super(key: key);

  final FocusNode focusNode;
  final TextLayout textLayout;
  // TODO: get rid of SuperSelectableTextState reference from this widget
  final SuperSelectableTextState selectableText;
  final Color color;
  final double width;
  final BorderRadius borderRadius;
  final AttributedText text;
  final TextSelection selection;
  final bool showCaret;
  final void Function(TextSelection newSelection) onDragSelectionChanged;

  @override
  _AndroidTextfieldControlsState createState() => _AndroidTextfieldControlsState();
}

class _AndroidTextfieldControlsState extends State<AndroidTextfieldControls> with SingleTickerProviderStateMixin {
  final _handleRadius = 8.0;

  // Controls the blinking caret animation.
  late CaretBlinkController _caretBlinkController;

  final _textFieldOffsetLink = LayerLink();

  OverlayEntry? _handlesOverlay;
  _HandleDragMode? _handleDragMode;
  Offset? _startDragCaretOffset;
  Offset? _dragDelta;

  @override
  void initState() {
    super.initState();

    _caretBlinkController = CaretBlinkController(
      tickerProvider: this,
    );
    _caretBlinkController.caretPosition = widget.selection.isCollapsed ? widget.selection.extent : null;

    widget.focusNode.addListener(_onFocusChange);
    if (widget.focusNode.hasFocus) {
      _showHandles();
    }
  }

  @override
  void didUpdateWidget(AndroidTextfieldControls oldWidget) {
    super.didUpdateWidget(oldWidget);

    _caretBlinkController.caretPosition = widget.selection.isCollapsed ? widget.selection.extent : null;

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (widget.selection != oldWidget.selection) {
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        if (mounted) {
          _rebuildHandles();
        }
      });
    }
  }

  @override
  void reassemble() {
    super.reassemble();

    // On Hot Reload we need to remove any visible overlay controls and then
    // bring them back a frame later to avoid having the controls attempt
    // to access the layout of the text. The text layout is not immediately
    // available upon Hot Reload. Accessing it results in an exception.
    if (_handlesOverlay != null) {
      _removeHandles();

      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        _showHandles();
      });
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _removeHandles();
    _caretBlinkController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (widget.focusNode.hasFocus) {
      _showHandles();
    } else {
      _removeHandles();
    }
  }

  void _showHandles() {
    if (_handlesOverlay == null) {
      _handlesOverlay = OverlayEntry(builder: (overlayContext) {
        print('Building handles');

        final textFieldBox = context.findRenderObject() as RenderBox;
        final textFieldGlobalOffset = textFieldBox.localToGlobal(Offset.zero);
        print('text field global offset: $textFieldGlobalOffset');

        return Stack(
          children: [
            _buildToolbar(),
            ..._buildHandles(),
          ],
        );
      });

      Overlay.of(context)!.insert(_handlesOverlay!);
    }
  }

  void _rebuildHandles() {
    _handlesOverlay?.markNeedsBuild();
  }

  void _removeHandles() {
    if (_handlesOverlay != null) {
      _handlesOverlay!.remove();
      _handlesOverlay = null;
    }
  }

  TextPosition? _getTextPositionAtOffset(Offset localOffset) {
    return widget.textLayout.getPositionAtOffset(localOffset);
  }

  TextSelection _getWordSelectionAt(TextPosition position) {
    return widget.selectableText.getWordSelectionAt(position);
  }

  void _onTapDown(TapDownDetails details) {
    print('Tapped on text field at ${details.localPosition}');

    widget.focusNode.requestFocus();

    // Calculate the position in the text where the user tapped.
    //
    // We show placeholder text when there is no text content. We don't want
    // to place the caret in the placeholder text, so when _currentText is
    // empty, explicitly set the text position to an offset of -1.
    final tapTextPosition = (widget.text.text.isNotEmpty
            ? _getTextPositionAtOffset(details.localPosition)
            : const TextPosition(offset: -1)) ??
        const TextPosition(offset: -1);

    setState(() {
      print('Tap text position: $tapTextPosition');
      widget.onDragSelectionChanged(TextSelection.collapsed(offset: tapTextPosition.offset));
    });
  }

  void _onDoubleTapDown(TapDownDetails details) {
    print('Double tap');
    widget.focusNode.requestFocus();

    // Calculate the position in the text where the user tapped.
    //
    // We show placeholder text when there is no text content. We don't want
    // to place the caret in the placeholder text, so when _currentText is
    // empty, explicitly set the text position to an offset of -1.
    final tapTextPosition = (widget.text.text.isNotEmpty
            ? _getTextPositionAtOffset(details.localPosition)
            : const TextPosition(offset: -1)) ??
        const TextPosition(offset: -1);

    setState(() {
      widget.onDragSelectionChanged(_getWordSelectionAt(tapTextPosition));
    });
  }

  void _onTripleTapDown(TapDownDetails details) {
    final tapTextPosition = widget.textLayout.getPositionAtOffset(details.localPosition);

    if (tapTextPosition != null) {
      setState(() {
        widget.onDragSelectionChanged(
            widget.selectableText.expandSelection(tapTextPosition, paragraphExpansionFilter, TextAffinity.downstream));
      });
    }
  }

  void _onTextPanStart(DragStartDetails details) {
    _handleDragMode = null;
    widget.onDragSelectionChanged(TextSelection.collapsed(
      offset: widget.textLayout.getPositionNearestToOffset(details.localPosition).offset,
    ));
  }

  void _onCollapsedHandleDragStart(DragStartDetails details) {
    _handleDragMode = _HandleDragMode.collapsed;

    // Note: We add half a line height to the caret offset because the caret
    //       treats the top of the line as (0, 0). Without adding half the height,
    //       the user would have to drag an entire line down before the caret
    //       moves to the line below the current line.
    _startDragCaretOffset = widget.textLayout.getOffsetAtPosition(widget.selection.extent) +
        Offset(0, (widget.textLayout.getLineHeightAtPosition(widget.selection.extent) / 2));
    _dragDelta = Offset.zero;
  }

  void _onBaseHandleDragStart(DragStartDetails details) {
    _handleDragMode = _HandleDragMode.base;

    // Note: We add half a line height to the caret offset because the caret
    //       treats the top of the line as (0, 0). Without adding half the height,
    //       the user would have to drag an entire line down before the caret
    //       moves to the line below the current line.
    _startDragCaretOffset = widget.textLayout.getOffsetAtPosition(widget.selection.base) +
        Offset(0, (widget.textLayout.getLineHeightAtPosition(widget.selection.base) / 2));
    _dragDelta = Offset.zero;
  }

  void _onExtentHandleDragStart(DragStartDetails details) {
    _handleDragMode = _HandleDragMode.extent;

    // Note: We add half a line height to the caret offset because the caret
    //       treats the top of the line as (0, 0). Without adding half the height,
    //       the user would have to drag an entire line down before the caret
    //       moves to the line below the current line.
    _startDragCaretOffset = widget.textLayout.getOffsetAtPosition(widget.selection.extent) +
        Offset(0, (widget.textLayout.getLineHeightAtPosition(widget.selection.extent) / 2));
    _dragDelta = Offset.zero;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    late TextPosition newTextPosition;
    if (_handleDragMode != null) {
      _dragDelta = _dragDelta! + details.delta;
      newTextPosition = widget.textLayout.getPositionNearestToOffset(_startDragCaretOffset! + _dragDelta!);
    } else {
      newTextPosition = widget.textLayout.getPositionNearestToOffset(details.localPosition);
    }

    print('New text position: $newTextPosition');

    switch (_handleDragMode) {
      case _HandleDragMode.base:
        widget.onDragSelectionChanged(
          TextSelection(
            baseOffset: newTextPosition.offset,
            extentOffset: widget.selection.extentOffset,
          ),
        );
        break;
      case _HandleDragMode.extent:
        widget.onDragSelectionChanged(
          TextSelection(
            baseOffset: widget.selection.baseOffset,
            extentOffset: newTextPosition.offset,
          ),
        );
        break;
      case _HandleDragMode.collapsed:
      default:
        widget.onDragSelectionChanged(
          TextSelection.collapsed(offset: newTextPosition.offset),
        );
        break;
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _handleDragMode = null;
  }

  void _onPanCancel() {
    _handleDragMode = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _textFieldOffsetLink,
      child: GestureDetector(
        onTap: () {
          // This GestureDetector is here to prevent taps from going further
          // up the tree. There must an issue with the custom gesture detector
          // used below that's allowing taps to bubble up even if handled.
          //
          // If this GestureDetector is placed any further down in this tree,
          // it won't block the touch event. But it does from right here.
          //
          // TODO: fix the custom gesture detector in the RawGestureDetector.
        },
        child: CustomPaint(
          painter: AndroidCursorPainter(
            blinkController: _caretBlinkController,
            textLayout: widget.textLayout,
            width: widget.width,
            borderRadius: widget.borderRadius,
            selection: widget.selection,
            caretColor: widget.color,
            isTextEmpty: widget.text.text.isEmpty,
            showCaret: widget.showCaret,
            showHandle: true,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  gestures: <Type, GestureRecognizerFactory>{
                    TapSequenceGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapSequenceGestureRecognizer>(
                      () => TapSequenceGestureRecognizer(),
                      (TapSequenceGestureRecognizer recognizer) {
                        recognizer
                          ..onTapDown = _onTapDown
                          ..onDoubleTapDown = _onDoubleTapDown
                          ..onTripleTapDown = _onTripleTapDown;
                      },
                    ),
                    PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                      () => PanGestureRecognizer(),
                      (PanGestureRecognizer recognizer) {
                        recognizer
                          ..onStart = widget.focusNode.hasFocus ? _onTextPanStart : null
                          ..onUpdate = widget.focusNode.hasFocus ? _onPanUpdate : null;
                        // ..onEnd = _onPanEnd
                        // ..onCancel = _onPanCancel;
                      },
                    ),
                  },
                ),
              ),
              // ..._buildHandles(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    if (widget.selection.extentOffset < 0) {
      return const SizedBox();
    }

    const toolbarGap = 8.0;
    Offset toolbarOffset;

    if (widget.selection.isCollapsed) {
      toolbarOffset = widget.textLayout.getOffsetAtPosition(widget.selection.extent) - const Offset(0, toolbarGap);
    } else {
      final selectionBoxes = widget.textLayout.getBoxesForSelection(widget.selection);
      Rect selectionBounds = selectionBoxes.first.toRect();
      for (int i = 1; i < selectionBoxes.length; ++i) {
        selectionBounds = selectionBounds.expandToInclude(selectionBoxes[i].toRect());
      }
      toolbarOffset = selectionBounds.topCenter - const Offset(0, toolbarGap);
    }

    return CompositedTransformFollower(
      link: _textFieldOffsetLink,
      child: Transform.translate(
        offset: toolbarOffset,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -1.0),
          child: AndroidTextfieldToolbar(
            onCutPressed: () {},
            onCopyPressed: () {},
            onPastePressed: () {},
            onSharePressed: () {},
            onSelectAllPressed: () {},
          ),
        ),
      ),
    );
  }

  List<Widget> _buildHandles() {
    if (widget.selection.extentOffset < 0) {
      // There is no selection. Draw nothing.
      return [];
    }

    print('Building handles for selection: ${widget.selection.extentOffset}');

    if (widget.selection.isCollapsed &&
        _handleDragMode != _HandleDragMode.base &&
        _handleDragMode != _HandleDragMode.extent) {
      // The selection is collapsed and the user is not dragging an expanded
      // selection. Draw 1 drag handle for the caret.
      final caretOffset = widget.textLayout.getOffsetAtPosition(widget.selection.extent);
      final lineHeight = widget.textLayout.getLineHeightAtPosition(widget.selection.extent);

      if (lineHeight == 0) {
        // A line height of zero indicates that the text isn't laid out yet.
        // Schedule a rebuild to give the text a frame to layout.
        _scheduleRebuildBecauseTextIsNotLaidOutYet();
        return [];
      }

      return [
        CompositedTransformFollower(
          link: _textFieldOffsetLink,
          offset: Offset(caretOffset.dx - _handleRadius, caretOffset.dy + lineHeight),
          child: GestureDetector(
            onPanStart: _onCollapsedHandleDragStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            onPanCancel: _onPanCancel,
            child: _buildHandle(_HandleType.single),
          ),
        ),
      ];
    }

    // The selection is expanded. Draw 2 drag handles.
    final baseCaretOffset = widget.textLayout.getOffsetAtPosition(widget.selection.base);
    final baseLineHeight = widget.textLayout.getLineHeightAtPosition(widget.selection.base);

    final extentCaretOffset = widget.textLayout.getOffsetAtPosition(widget.selection.extent);
    final extentLineHeight = widget.textLayout.getLineHeightAtPosition(widget.selection.extent);

    if (baseLineHeight == 0 || extentLineHeight == 0) {
      // A line height of zero indicates that the text isn't laid out yet.
      // Schedule a rebuild to give the text a frame to layout.
      _scheduleRebuildBecauseTextIsNotLaidOutYet();
      return [];
    }

    // TODO: handle the case with no text affinity and then query widget.selection!.affinity
    final selectionDirection =
        widget.selection.extentOffset >= widget.selection.baseOffset ? TextAffinity.downstream : TextAffinity.upstream;

    // TODO: handle RTL text orientation
    final upstreamCaretOffset = selectionDirection == TextAffinity.downstream ? baseCaretOffset : extentCaretOffset;
    final upstreamLineHeight = selectionDirection == TextAffinity.downstream ? baseLineHeight : extentLineHeight;

    final downstreamCaretOffset = selectionDirection == TextAffinity.downstream ? extentCaretOffset : baseCaretOffset;
    final downstreamLineHeight = selectionDirection == TextAffinity.downstream ? extentLineHeight : baseLineHeight;

    return [
      // Paint the left-bounding handle
      CompositedTransformFollower(
        link: _textFieldOffsetLink,
        offset: Offset(upstreamCaretOffset.dx - (2 * _handleRadius), upstreamCaretOffset.dy + upstreamLineHeight),
        child: GestureDetector(
          onPanStart: selectionDirection == TextAffinity.downstream ? _onBaseHandleDragStart : _onExtentHandleDragStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
          child: _buildHandle(_HandleType.left),
        ),
      ),
      // Paint the right-bounding handle
      CompositedTransformFollower(
        link: _textFieldOffsetLink,
        offset: Offset(downstreamCaretOffset.dx, downstreamCaretOffset.dy + downstreamLineHeight),
        child: GestureDetector(
          onPanStart: selectionDirection == TextAffinity.downstream ? _onExtentHandleDragStart : _onBaseHandleDragStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
          child: _buildHandle(_HandleType.right),
        ),
      ),
    ];
  }

  Widget _buildHandle(_HandleType type) {
    switch (type) {
      case _HandleType.none:
        return const SizedBox();
      case _HandleType.single:
        return AndroidTextfieldCollapsedHandle(color: widget.color, radius: _handleRadius);
      case _HandleType.left:
        return AndroidTextfieldLeftHandle(color: widget.color, radius: _handleRadius);
      case _HandleType.right:
        return AndroidTextfieldRightHandle(color: widget.color, radius: _handleRadius);
    }
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

enum _HandleDragMode {
  collapsed,
  base,
  extent,
}

enum _HandleType {
  none,
  single,
  left,
  right,
}
