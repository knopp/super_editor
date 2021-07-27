import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/multi_tap_gesture.dart';
import 'package:super_editor/src/infrastructure/super_selectable_text.dart';
import 'package:super_editor/src/infrastructure/super_textfield/super_textfield.dart';
import 'package:super_editor/src/infrastructure/text_layout.dart';

import '_editing_controls.dart';
import '_handles.dart';

// TODO: only scroll whole lines
// TODO: ensure the extent is visible after a drag, after a scroll change,
//       and after a content change
// TODO: confine the handles to the viewport, in terms of their focal point
// TODO: handle larger text, along with height multipliers
//       - move any line height estimations out of this class and into SuperSelectableText
// TODO: secondary tap-to-scrolls on drag handles seems to always trigger
//       a tap on the textfield rather than a tap/drag on the handle

// TODO: report a specific focal point to the toolbar rather than passing
//       a whole widget reference to have the toolbar do that, itself.

// TODO: fix issue where sometimes recurring tapping does not place the
//       caret, or does not select a word

// TODO: add floating cursor when dragging, including turning the regular
//       caret into a non-blinking light grey

// TODO: listen for screen inset changes and rebuild
//       - verify by starting with keyboard down, then start dragging on big
//         textfield near bottom. See if things are still in the right place
//         when the keyboard expands and you're still dragging

// TODO: convert to newer logger
final _log = Logger(scope: '_user_interaction.dart');

/// iOS text field user interaction surface.
///
/// This widget is intended to be displayed in the foreground of
/// a [SuperSelectableText] widget.
///
/// This widget recognizes and acts upon various user interactions:
///
///  * Tap: Place a collapsed text selection at the tapped location
///    in text.
///  * Double-Tap: Select the word surrounding the tapped location
///  * Triple-Tap: Select the paragraph surrounding the tapped location
///  * Drag: Move a collapsed selection wherever the user drags, while
///    displaying a magnifying glass.
///  * Drag a selection handle: Move the base or extent of the current
///    text selection to wherever the user drags, while displaying a
///    magnifying glass.
///
/// Drag handles, a magnifying glass, and an editing toolbar are displayed
/// based on how the user interacts with this widget. Those UI elements
/// are displayed in the app's [Overlay] so that they're free to operate
/// outside the bounds of the associated text field.
///
/// Selection changes are made via the given [textController].
class IOSTextfieldInteractor extends StatefulWidget {
  const IOSTextfieldInteractor({
    Key? key,
    required this.focusNode,
    required this.textFieldLayerLink,
    required this.textController,
    required this.editingController,
    required this.scrollKey,
    required this.scrollController,
    required this.viewportHeight,
    required this.selectableTextKey,
    required this.isMultiline,
    required this.handleColor,
    this.showDebugPaint = false,
    required this.child,
  }) : super(key: key);

  /// [FocusNode] for the text field that contains this [IOSTextFieldInteractor].
  ///
  /// [IOSTextFieldInteractor] only shows editing controls, and listens for drag
  /// events when [focusNode] has focus.
  ///
  /// [IOSTextFieldInteractor] requests focus when the user taps on it.
  final FocusNode focusNode;

  /// [LayerLink] that follows the text field that contains this
  /// [IOSExtFieldInteractor].
  ///
  /// [textFieldLayerLink] is used to anchor the editing controls.
  final LayerLink textFieldLayerLink;

  // TODO: this key is ambiguous with others. I don't think we need it.
  final GlobalKey<IOSTextfieldInteractorState> scrollKey;

  /// [TextController] used to read the current selection to display
  /// editing controls, and used to update the selection based on
  /// user interactions.
  final AttributedTextEditingController textController;

  final IOSEditingOverlayController editingController;

  /// [ScrollController] that controls the scroll offset of this [IOSTextfieldInteractor].
  final ScrollController scrollController;

  /// The height of the viewport for this text field.
  ///
  /// If [null] then the viewport is permitted to grow/shrink to any desired height.
  final double? viewportHeight;

  /// [GlobalKey] that references the [SuperSelectableText] that lays out
  /// and renders the text within the text field that owns this
  /// [IOSTextFieldInteractor].
  final GlobalKey<SuperSelectableTextState> selectableTextKey;

  /// Whether the text field that owns this [IOSTextFieldInteractor] is
  /// a multiline text field.
  final bool isMultiline;

  /// The color of expanded selection drag handles.
  final Color handleColor;

  /// Whether to paint debugging guides and regions.
  final bool showDebugPaint;

  /// The child widget.
  final Widget child;

  @override
  IOSTextfieldInteractorState createState() => IOSTextfieldInteractorState();
}

class IOSTextfieldInteractorState extends State<IOSTextfieldInteractor> with TickerProviderStateMixin {
  final _singleLineFieldAutoScrollGap = 24.0;
  final _mulitlineFieldAutoScrollGap = 20.0;

  TextSelection? _selectionBeforeSingleTapDown;

  // Whether the user is dragging a collapsed selection, base
  // handle, or extent handle.
  HandleDragMode? _handleDragMode;

  // The latest offset during a user's drag gesture.
  Offset? _globalDragOffset;
  Offset? _dragOffset;

  final _textFieldViewportKey = GlobalKey();
  final _textContentOffsetLink = LayerLink();
  bool _scrollToStartOnTick = false;
  bool _scrollToEndOnTick = false;
  double _scrollAmountPerFrame = 0;
  final _scrollChangeListeners = <VoidCallback>{};

  late Ticker _ticker;

  // OverlayEntry that displays the toolbar and magnifier, and
  // positions the invisible touch targets for base/extent
  // dragging.
  OverlayEntry? _controlsOverlayEntry;

  @override
  void initState() {
    super.initState();

    _ticker = createTicker(_onTick);

    widget.focusNode.addListener(_onFocusChange);
    if (widget.focusNode.hasFocus) {
      _showHandles();
    }

    widget.textController.addListener(_onTextControllerChange);

    widget.scrollController.addListener(_onScrollChange);
  }

  @override
  void didUpdateWidget(IOSTextfieldInteractor oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (widget.scrollKey != oldWidget.scrollKey) {
      oldWidget.scrollKey.currentState?.removeScrollListener(_onScrollChange);
      widget.scrollKey.currentState!.addScrollListener(_onScrollChange);
    }

    if (widget.textController != oldWidget.textController) {
      oldWidget.textController.removeListener(_onTextControllerChange);
      widget.textController.addListener(_onTextControllerChange);
    }

    if (widget.viewportHeight != oldWidget.viewportHeight) {
      // After the current layout, ensure that the current text
      // selection is visible.
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        if (mounted) {
          _ensureTextPositionIsVisible(widget.textController.selection.extent);
        }
      });
    }

    if (widget.scrollController != oldWidget.scrollController) {
      oldWidget.scrollController.removeListener(_onScrollChange);
      widget.scrollController.addListener(_onScrollChange);
    }

    if (widget.showDebugPaint != oldWidget.showDebugPaint) {
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        _rebuildHandles();
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
    if (_controlsOverlayEntry != null) {
      _removeHandles();

      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        _showHandles();
      });
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScrollChange);
    _scrollChangeListeners.clear();
    _ticker.dispose();
    widget.scrollKey.currentState?.removeScrollListener(_onScrollChange);
    widget.focusNode.removeListener(_onFocusChange);
    _removeHandles();
    super.dispose();
  }

  void _onFocusChange() {
    print('Focus change for interactor ($hashCode), has focus: ${widget.focusNode.hasFocus}');
    if (widget.focusNode.hasFocus) {
      _showHandles();
    } else {
      _removeHandles();
    }
  }

  void _onTextControllerChange() {
    if (widget.focusNode.hasFocus) {
      print('Rebuilding handles for interactor ($hashCode)');
      _rebuildHandles();
    }
  }

  /// Displays [IOSEditingControls] in the app's [Overlay], if not already
  /// displayed.
  void _showHandles() {
    if (_controlsOverlayEntry == null) {
      _controlsOverlayEntry = OverlayEntry(builder: (overlayContext) {
        return IOSEditingControls(
          editingController: widget.editingController,
          textController: widget.textController,
          textFieldViewportKey: _textFieldViewportKey,
          selectableTextKey: widget.selectableTextKey,
          textFieldLayerLink: widget.textFieldLayerLink,
          textContentOffsetLink: _textContentOffsetLink,
          interactorKey: widget.scrollKey,
          selection: widget.textController.selection,
          handleDragMode: _handleDragMode,
          handleColor: widget.handleColor,
          showDebugPaint: widget.showDebugPaint,
          onBaseHandleDragStart: _onBaseHandleDragStart,
          onExtentHandleDragStart: _onExtentHandleDragStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
        );
      });

      Overlay.of(context)!.insert(_controlsOverlayEntry!);
    }
  }

  /// Rebuilds the [IOSEditingControls] in the app's [Overlay], if
  /// they're currently displayed.
  void _rebuildHandles() {
    _controlsOverlayEntry?.markNeedsBuild();
  }

  /// Removes [IOSEditingControls] from the app's [Overlay], if they're
  /// currently displayed.
  void _removeHandles() {
    if (_controlsOverlayEntry != null) {
      _controlsOverlayEntry!.remove();
      _controlsOverlayEntry = null;
    }
  }

  void _onTapDown(TapDownDetails details) {
    print('_onTapDown');

    widget.focusNode.requestFocus();

    // When the user drags, the toolbar should not be visible.
    // A drag can begin with a tap down, so we hide the toolbar
    // preemptively.
    widget.editingController.hideToolbar();

    _selectionBeforeSingleTapDown = widget.textController.selection;

    final tapTextPosition = _getTextPositionAtOffset(details.localPosition);
    if (tapTextPosition == null) {
      // This shouldn't be possible, but we'll ignore the tap if we can't
      // map it to a position within the text.
      print('Warning: received a tap-down event on IOSTextFieldInteractor that is not on top of any text');
      return;
    }

    // Update the text selection to a collapsed selection where the user tapped.
    print('Previous selection: ${widget.textController.selection}');
    widget.textController.selection = TextSelection.collapsed(offset: tapTextPosition.offset);
    print('New selection: ${widget.textController.selection}');
  }

  void _onTapUp(TapUpDetails details) {
    print('_onTapUp()');
    // If the user tapped on a collapsed caret, or tapped on an
    // expanded selection, toggle the toolbar appearance.

    final tapTextPosition = _getTextPositionAtOffset(details.localPosition);
    if (tapTextPosition == null) {
      // This shouldn't be possible, but we'll ignore the tap if we can't
      // map it to a position within the text.
      print('Warning: received a tap-up event on IOSTextFieldInteractor that is not on top of any text');
      return;
    }

    final didTapOnExistingSelection = widget.textController.selection.isCollapsed
        ? tapTextPosition == _selectionBeforeSingleTapDown!.extent
        : tapTextPosition.offset >= _selectionBeforeSingleTapDown!.start &&
            tapTextPosition.offset <= _selectionBeforeSingleTapDown!.end;

    if (didTapOnExistingSelection) {
      // Toggle the toolbar display when the user taps on the collapsed caret,
      // or on top of an existing selection.
      widget.editingController.toggleToolbar();
    } else {
      // The user tapped somewhere in the text outside any existing selection.
      // Hide the toolbar.
      widget.editingController.hideToolbar();
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    print('Double tap');
    widget.focusNode.requestFocus();

    // When the user released the first tap, the toolbar was set
    // to visible. At the beginning of a double-tap, make it invisible
    // again.
    widget.editingController.hideToolbar();

    final tapTextPosition = _getTextPositionAtOffset(details.localPosition);
    if (tapTextPosition != null) {
      setState(() {
        final wordSelection = _getWordSelectionAt(tapTextPosition);

        widget.textController.selection = wordSelection;

        if (!wordSelection.isCollapsed) {
          widget.editingController.showToolbar();
        }
      });
    }
  }

  void _onTripleTapDown(TapDownDetails details) {
    final tapTextPosition = widget.selectableTextKey.currentState!.getPositionAtOffset(details.localPosition);

    widget.textController.selection = widget.selectableTextKey.currentState!
        .expandSelection(tapTextPosition, paragraphExpansionFilter, TextAffinity.downstream);
  }

  void _onTextPanStart(DragStartDetails details) {
    print('_onTextPanStart()');
    setState(() {
      _handleDragMode = HandleDragMode.collapsed;
      _globalDragOffset = details.globalPosition;
      _dragOffset = details.localPosition;
    });
  }

  void _onBaseHandleDragStart(DragStartDetails details) {
    print('_onBaseHandleDragStart');

    _autoScrollIfNearBoundary(details.globalPosition);

    setState(() {
      widget.editingController.hideToolbar();
      _handleDragMode = HandleDragMode.base;
      _globalDragOffset = details.globalPosition;
      _dragOffset = details.globalPosition;
    });
  }

  void _onExtentHandleDragStart(DragStartDetails details) {
    print('_onExtentHandleDragStart()');

    _autoScrollIfNearBoundary(details.globalPosition);

    setState(() {
      widget.editingController.hideToolbar();
      _handleDragMode = HandleDragMode.extent;
      _globalDragOffset = details.globalPosition;
      _dragOffset = details.globalPosition;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    print('_onPanUpdate handle mode: $_handleDragMode, global position: ${details.globalPosition}');

    switch (_handleDragMode) {
      case HandleDragMode.base:
        widget.textController.selection = widget.textController.selection.copyWith(
          baseOffset: _globalOffsetToTextPosition(details.globalPosition).offset,
        );
        break;
      case HandleDragMode.extent:
        widget.textController.selection = widget.textController.selection.copyWith(
          extentOffset: _globalOffsetToTextPosition(details.globalPosition).offset,
        );
        break;
      case HandleDragMode.collapsed:
      default:
        widget.textController.selection = TextSelection.collapsed(
          offset: _globalOffsetToTextPosition(details.globalPosition).offset,
        );
        break;
    }

    _autoScrollIfNearBoundary(details.globalPosition);

    setState(() {
      _globalDragOffset = _globalDragOffset! + details.delta;
      _dragOffset = _dragOffset! + details.delta;
      widget.editingController.showMagnifier(_globalDragOffset!);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    print('_onPanEnd()');
    _onHandleDragEnd();
  }

  void _onPanCancel() {
    print('_onPanCancel()');
    _onHandleDragEnd();
  }

  void _onHandleDragEnd() {
    print('_onHandleDragEnd()');
    stopScrolling();

    switch (_handleDragMode) {
      case HandleDragMode.collapsed:
        _ensureTextPositionIsVisible(widget.textController.selection.extent);
        break;
      case HandleDragMode.base:
        _ensureTextPositionIsVisible(widget.textController.selection.base);
        break;
      case HandleDragMode.extent:
        _ensureTextPositionIsVisible(widget.textController.selection.extent);
        break;
      default:
        print('WARNING: _onHandleDragEnd() with no _handleDragMode');
        break;
    }

    if (_controlsOverlayEntry != null) {
      _controlsOverlayEntry!.markNeedsBuild();
    }

    setState(() {
      _handleDragMode = null;
      widget.editingController.hideMagnifier();

      if (!widget.textController.selection.isCollapsed) {
        widget.editingController.showToolbar();
      }
    });
  }

  void addScrollListener(VoidCallback callback) {
    _scrollChangeListeners.add(callback);
  }

  void removeScrollListener(VoidCallback callback) {
    _scrollChangeListeners.remove(callback);
  }

  void _onScrollChange() {
    if (_handleDragMode == HandleDragMode.extent) {
      final newExtent = _getTextPositionAtOffset(_dragOffset!);
      widget.textController.selection = widget.textController.selection.copyWith(
        extentOffset: newExtent!.offset,
      );
    } else if (_handleDragMode == HandleDragMode.base) {
      final newBase = _getTextPositionAtOffset(_dragOffset!);
      widget.textController.selection = widget.textController.selection.copyWith(
        baseOffset: newBase!.offset,
      );
    }

    if (_controlsOverlayEntry != null) {
      _rebuildHandles();
    }

    for (final listener in _scrollChangeListeners) {
      listener();
    }
  }

  /// Returns the current scroll offset as a 2-dimensional [Offset].
  ///
  /// When scrolling vertically, [Offset.dx] is zero and [Offset.dy]
  /// is the current scroll position.
  ///
  /// When scrolling horizontally, [Offset.dx] is the current scroll
  /// position and [Offset.dy] is zero.
  Offset get scrollOffset {
    if (widget.isMultiline) {
      return Offset(0, -widget.scrollController.offset);
    } else {
      return Offset(-widget.scrollController.offset, 0);
    }
  }

  /// Converts a text offset to a viewport offset for the [ScrollView]
  /// within this [IOSTextFieldInteractor].
  ///
  /// This [IOSTextFieldInteractor] displays a [ScrollView], which
  /// contains the text content for the text field. This method
  /// converts an offset within the child text area to an offset
  /// that is relative to the top-left corner of the [ScrollView].
  ///
  /// See also:
  ///
  ///  * [_viewportOffsetToTextOffset]
  Offset textOffsetToViewportOffset(Offset textOffset) {
    if (widget.isMultiline) {
      return textOffset.translate(0, -widget.scrollController.offset);
    } else {
      return textOffset.translate(-widget.scrollController.offset, 0);
    }
  }

  /// Converts an offset within the [ScrollView] in this [IOSTextFieldInteractor]
  /// to an offset within the child text.
  ///
  /// See also:
  ///
  ///  * [_textOffsetToViewportOffset]
  Offset _viewportOffsetToTextOffset(Offset viewportOffset) {
    if (widget.isMultiline) {
      return viewportOffset.translate(0, widget.scrollController.offset);
    } else {
      return viewportOffset.translate(widget.scrollController.offset, 0);
    }
  }

  /// Converts a screen-level offset to an offset relative to the top-left
  /// corner of the text within this text field.
  Offset _globalOffsetToTextOffset(Offset globalOffset) {
    final textBox = widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox;
    return textBox.globalToLocal(globalOffset);
  }

  /// Converts a screen-level offset to a [TextPosition] that sits at that
  /// global offset.
  TextPosition _globalOffsetToTextPosition(Offset globalOffset) {
    return widget.selectableTextKey.currentState!.getPositionNearestToOffset(
      _globalOffsetToTextOffset(globalOffset),
    );
  }

  /// Returns the [SuperSelectableTextState] that lays out and renders the
  /// text in this text field.
  SuperSelectableTextState get _text => widget.selectableTextKey.currentState!;

  /// Scrolls to show the given [position], if necessary.
  void _ensureTextPositionIsVisible(TextPosition position) {
    if (!widget.isMultiline) {
      _ensureTextPositionIsVisibleInSingleLineTextField(position);
    } else {
      _ensureTextPositionIsVisibleInMultilineTextField(position);
    }
  }

  void _ensureTextPositionIsVisibleInSingleLineTextField(TextPosition position) {
    final textOffset = _text.getOffsetAtPosition(position);

    const gutterExtent = 24; // _dragGutterExtent

    final myBox = context.findRenderObject() as RenderBox;
    final beyondLeftExtent = min(textOffset.dx - widget.scrollController.offset - gutterExtent, 0).abs();
    final beyondRightExtent = max(textOffset.dx - myBox.size.width - widget.scrollController.offset + gutterExtent, 0);

    if (beyondLeftExtent > 0) {
      final newScrollPosition = (widget.scrollController.offset - beyondLeftExtent)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (beyondRightExtent > 0) {
      final newScrollPosition = (beyondRightExtent + widget.scrollController.offset)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  void _ensureTextPositionIsVisibleInMultilineTextField(TextPosition textPosition) {
    final textOffset = _text.getOffsetAtPosition(textPosition);
    final lineHeight = widget.selectableTextKey.currentState!.getLineHeightAtPosition(textPosition);
    if (lineHeight == 0) {
      // Text is not laid out yet.
      return;
    }

    const gutterExtent = 0; // _dragGutterExtent
    final extentLineIndex = (textOffset.dy / lineHeight).round();

    final myBox = context.findRenderObject() as RenderBox;
    final beyondTopExtent = min<double>(textOffset.dy - widget.scrollController.offset - gutterExtent, 0).abs();
    final beyondBottomExtent = max<double>(
        ((extentLineIndex + 1) * lineHeight) -
            myBox.size.height -
            widget.scrollController.offset +
            gutterExtent +
            (lineHeight / 2), // manual adjustment to avoid line getting half cut off
        0);

    _log.log('_ensureSelectionExtentIsVisible', 'Ensuring extent is visible.');
    _log.log('_ensureSelectionExtentIsVisible', ' - interaction size: ${myBox.size}');
    _log.log('_ensureSelectionExtentIsVisible', ' - scroll extent: ${widget.scrollController.offset}');
    _log.log('_ensureSelectionExtentIsVisible', ' - extent rect: $textOffset');
    _log.log('_ensureSelectionExtentIsVisible', ' - beyond top: $beyondTopExtent');
    _log.log('_ensureSelectionExtentIsVisible', ' - beyond bottom: $beyondBottomExtent');

    if (beyondTopExtent > 0) {
      final newScrollPosition = (widget.scrollController.offset - beyondTopExtent)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (beyondBottomExtent > 0) {
      final newScrollPosition = (beyondBottomExtent + widget.scrollController.offset)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  /// Start repeatedly scrolling if the [focalPointInGlobalCoords] is
  /// in an auto-scroll boundary.
  void _autoScrollIfNearBoundary(Offset focalPointInGlobalCoords) {
    if (widget.isMultiline) {
      _autoScrollIfNearVerticalBoundary(focalPointInGlobalCoords);
    } else {
      _autoScrollIfNearHorizontalBoundary(focalPointInGlobalCoords);
    }
  }

  void _autoScrollIfNearHorizontalBoundary(Offset focalPointInGlobalCoords) {
    final textFieldBox = context.findRenderObject() as RenderBox;
    final textFieldViewportOffset = textFieldBox.globalToLocal(focalPointInGlobalCoords);
    // print('_scrollIfNearHorizontalBoundary: $textFieldViewportOffset');
    if (textFieldViewportOffset.dx < _singleLineFieldAutoScrollGap) {
      // print('Drag offset is near start. Scrolling left');
      _startScrollingToStart(amountPerFrame: 2);
    } else if (textFieldViewportOffset.dx > (textFieldBox.size.width - _singleLineFieldAutoScrollGap)) {
      // print('Drag offset is near end. Scrolling right');
      startScrollingToEnd(amountPerFrame: 2);
    } else {
      // print('Stopping auto-scrolling');
      stopScrolling();
    }
  }

  void _autoScrollIfNearVerticalBoundary(Offset focalPointInGlobalCoords) {
    final textFieldViewportBox = context.findRenderObject() as RenderBox;
    final textFieldViewportOffset = textFieldViewportBox.globalToLocal(focalPointInGlobalCoords);

    final textOffsetInFirstVisibleLine = (widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox)
        .globalToLocal(Offset.zero, ancestor: textFieldViewportBox);
    final textPositionInFirstVisibleLine =
        widget.selectableTextKey.currentState!.getPositionNearestToOffset(textOffsetInFirstVisibleLine);
    final lineHeightAtTopOfViewport =
        widget.selectableTextKey.currentState!.getLineHeightAtPosition(textPositionInFirstVisibleLine);

    final textOffsetInLastVisibleLine = (widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox)
        .globalToLocal(Offset(0, textFieldViewportBox.size.height), ancestor: textFieldViewportBox);
    final textPositionInLastVisibleLine =
        widget.selectableTextKey.currentState!.getPositionNearestToOffset(textOffsetInLastVisibleLine);
    final lineHeightAtBottomOfViewport =
        widget.selectableTextKey.currentState!.getLineHeightAtPosition(textPositionInLastVisibleLine);

    if (textFieldViewportOffset.dy < _mulitlineFieldAutoScrollGap) {
      // print('Drag offset is near start. Scrolling up');
      _startScrollingToStart(amountPerFrame: 2);
    } else if (textFieldViewportOffset.dy > (textFieldViewportBox.size.height - _mulitlineFieldAutoScrollGap)) {
      // print('Drag offset is near end. Scrolling down');
      startScrollingToEnd(amountPerFrame: 2);
    } else {
      stopScrolling();
    }
  }

  /// Starts auto-scrolling towards the starting edge of the text.
  void _startScrollingToStart({required double amountPerFrame}) {
    assert(amountPerFrame > 0);

    if (_scrollToStartOnTick) {
      _scrollAmountPerFrame = amountPerFrame;
      return;
    }

    _scrollToStartOnTick = true;
    _ticker.start();
  }

  /// Stops scrolling towards the starting edge of the text.
  void stopScrollingToStart() {
    if (!_scrollToStartOnTick) {
      return;
    }

    _scrollToStartOnTick = false;
    _scrollAmountPerFrame = 0;
    _ticker.stop();
  }

  /// Starts auto-scrolling towards the ending edge of the text.
  void startScrollingToEnd({required double amountPerFrame}) {
    assert(amountPerFrame > 0);

    if (_scrollToEndOnTick) {
      _scrollAmountPerFrame = amountPerFrame;
      return;
    }

    _scrollToEndOnTick = true;
    _ticker.start();
  }

  /// Stops scrolling towards the ending edge of the text.
  void stopScrollingToEnd() {
    if (!_scrollToEndOnTick) {
      return;
    }

    _scrollToEndOnTick = false;
    _scrollAmountPerFrame = 0;
    _ticker.stop();
  }

  /// Stops auto-scrolling.
  void stopScrolling() {
    stopScrollingToStart();
    stopScrollingToEnd();
  }

  /// Processes a single frame of auto-scrolling.
  void _onTick(elapsedTime) {
    if (_scrollToStartOnTick) {
      _doScrollToStart();
    }
    if (_scrollToEndOnTick) {
      _doScrollToEnd();
    }
  }

  /// Moves the scroll position towards the start of the text for a single frame
  /// of animated scrolling.
  void _doScrollToStart() {
    if (widget.scrollController.offset <= 0) {
      stopScrollingToStart();
      return;
    }

    widget.scrollController.jumpTo(widget.scrollController.offset - _scrollAmountPerFrame);
  }

  /// Moves the scroll position towards the end of the text for a single frame
  /// of animated scrolling.
  void _doScrollToEnd() {
    if (widget.scrollController.offset >= widget.scrollController.position.maxScrollExtent) {
      stopScrollingToEnd();
      return;
    }

    widget.scrollController.jumpTo(widget.scrollController.offset + _scrollAmountPerFrame);
  }

  /// Returns the [TextPosition] sitting at the given [localOffset] within
  /// this [IOSTextFieldInteractor].
  TextPosition? _getTextPositionAtOffset(Offset localOffset) {
    final scrollOffset =
        widget.isMultiline ? Offset(0, widget.scrollController.offset) : Offset(widget.scrollController.offset, 0);

    // Calculate the position in the text where the user tapped.
    //
    // We show placeholder text when there is no text content. We don't want
    // to place the caret in the placeholder text, so when _currentText is
    // empty, explicitly set the text position to an offset of -1.
    return (widget.textController.text.text.isNotEmpty
        ? widget.selectableTextKey.currentState!.getPositionAtOffset(localOffset + scrollOffset)
        : const TextPosition(offset: -1));
  }

  /// Returns a [TextSelection] that selects the word surrounding the given
  /// [position].
  TextSelection _getWordSelectionAt(TextPosition position) {
    return widget.selectableTextKey.currentState!.getWordSelectionAt(position);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _textContentOffsetLink,
      child: GestureDetector(
        onTap: () {
          print('Intercepting single tap');
          // This GestureDetector is here to prevent taps from going further
          // up the tree. There must an issue with the custom gesture detector
          // used below that's allowing taps to bubble up even if handled.
          //
          // If this GestureDetector is placed any further down in this tree,
          // it won't block the touch event. But it does from right here.
          //
          // TODO: fix the custom gesture detector in the RawGestureDetector.
        },
        onDoubleTap: () {
          print('Intercepting double tap');
          // no-op
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: widget.showDebugPaint ? Border.all(color: Colors.purple) : const Border(),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildScrollView(child: widget.child),
              if (widget.textController.selection.extentOffset >= 0) _buildExtentTrackerForMagnifier(),
              _buildTapAndDragDetector(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScrollView({
    required Widget child,
  }) {
    return SizedBox(
      height: widget.viewportHeight,
      child: Stack(
        children: [
          SingleChildScrollView(
            key: _textFieldViewportKey,
            controller: widget.scrollController,
            physics: const NeverScrollableScrollPhysics(),
            scrollDirection: widget.isMultiline ? Axis.vertical : Axis.horizontal,
            child: child,
          ),
          if (widget.showDebugPaint) ..._buildDebugScrollRegions(),
        ],
      ),
    );
  }

  Widget _buildTapAndDragDetector() {
    return Positioned(
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
                ..onTapUp = _onTapUp
                ..onDoubleTapDown = _onDoubleTapDown
                ..onTripleTapDown = _onTripleTapDown;
            },
          ),
          PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(),
            (PanGestureRecognizer recognizer) {
              recognizer
                ..onStart = widget.focusNode.hasFocus ? _onTextPanStart : null
                ..onUpdate = widget.focusNode.hasFocus ? _onPanUpdate : null
                ..onEnd = widget.focusNode.hasFocus || _handleDragMode != null ? _onPanEnd : null
                ..onCancel = widget.focusNode.hasFocus || _handleDragMode != null ? _onPanCancel : null;
            },
          ),
        },
      ),
    );
  }

  /// Paints guides where the auto-scroll regions sit.
  List<Widget> _buildDebugScrollRegions() {
    if (widget.isMultiline) {
      return [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: Container(
              height: _mulitlineFieldAutoScrollGap,
              color: Colors.purpleAccent.withOpacity(0.5),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              height: _mulitlineFieldAutoScrollGap,
              color: Colors.purpleAccent.withOpacity(0.5),
            ),
          ),
        ),
      ];
    } else {
      return [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: Container(
            width: _singleLineFieldAutoScrollGap,
            color: Colors.purpleAccent.withOpacity(0.5),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Container(
            width: _singleLineFieldAutoScrollGap,
            color: Colors.purpleAccent.withOpacity(0.5),
          ),
        ),
      ];
    }
  }

  /// Builds a tracking widget at the selection extent offset.
  ///
  /// The extent widget is tracked via [_draggingHandleLink]
  Widget _buildExtentTrackerForMagnifier() {
    if (_handleDragMode != HandleDragMode.collapsed) {
      return const SizedBox();
    }

    return Positioned(
      left: _dragOffset!.dx,
      top: _dragOffset!.dy,
      child: CompositedTransformTarget(
        link: widget.editingController.magnifierFocalPoint,
        child: widget.showDebugPaint
            ? FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: Container(
                  width: 20,
                  height: 20,
                  color: Colors.purpleAccent.withOpacity(0.5),
                ),
              )
            : const SizedBox(width: 1, height: 1),
      ),
    );
  }
}
