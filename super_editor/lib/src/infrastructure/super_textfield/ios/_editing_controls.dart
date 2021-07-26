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

import '_handles.dart';
import '_magnifier.dart';
import '_toolbar.dart';

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
final _log = Logger(scope: '_editing_controls.dart');

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
  _HandleDragMode? _handleDragMode;

  // LayerLink that is positioned wherever the current dragging
  // handle is, whether that's a collapsed handle, base handle,
  // or extent handle.
  final _draggingHandleLink = LayerLink();

  // The scroll offset when the user begins a drag gesture.
  //
  // This is combined with the drag delta to determine the location
  // in text where the user is dragging.
  Offset? _startDragScrollOffset;

  // The latest offset during a user's drag gesture.
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
  bool _showToolbar = false;
  bool _showMagnifier = false;

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
          ensureSelectionIsVisible(true);
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
    if (widget.focusNode.hasFocus) {
      _showHandles();
    } else {
      _removeHandles();
    }
  }

  void _showHandles() {
    if (_controlsOverlayEntry == null) {
      _controlsOverlayEntry = OverlayEntry(builder: (overlayContext) {
        return EditingControls(
          textFieldViewportKey: _textFieldViewportKey,
          selectableTextKey: widget.selectableTextKey,
          textFieldLayerLink: widget.textFieldLayerLink,
          textContentOffsetLink: _textContentOffsetLink,
          scrollKey: widget.scrollKey,
          selection: widget.textController.selection,
          showToolbar: _showToolbar,
          showMagnifier: _showMagnifier,
          handleDragMode: _handleDragMode,
          draggingHandleLink: _draggingHandleLink,
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

  void _rebuildHandles() {
    _controlsOverlayEntry?.markNeedsBuild();
  }

  void _removeHandles() {
    if (_controlsOverlayEntry != null) {
      _controlsOverlayEntry!.remove();
      _controlsOverlayEntry = null;
    }
  }

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

  TextSelection _getWordSelectionAt(TextPosition position) {
    return widget.selectableTextKey.currentState!.getWordSelectionAt(position);
  }

  void _onTapDown(TapDownDetails details) {
    print('Tapped on text field at ${details.localPosition}');

    widget.focusNode.requestFocus();

    // When the user drags, the toolbar should not be visible.
    // A drag can begin with a tap down, so we hide the toolbar
    // preemptively.
    setState(() {
      _showToolbar = false;
    });

    _selectionBeforeSingleTapDown = widget.textController.selection;

    final tapTextPosition = _getTextPositionAtOffset(details.localPosition);
    if (tapTextPosition == null) {
      // This shouldn't be possible, but we'll ignore the tap if we can't
      // map it to a position within the text.
      print('Warning: received a tap-down event on editing_controls that is not on top of any text');
      return;
    }

    widget.textController.selection = TextSelection.collapsed(offset: tapTextPosition.offset);
  }

  void _onTapUp(TapUpDetails details) {
    print('_onTapUp()');
    // If the user tapped on a collapsed caret, or tapped on an
    // expanded selection, toggle the toolbar appearance.
    setState(() {
      final tapTextPosition = _getTextPositionAtOffset(details.localPosition);
      if (tapTextPosition == null) {
        // This shouldn't be possible, but we'll ignore the tap if we can't
        // map it to a position within the text.
        print('Warning: received a tap-up event on editing_controls that is not on top of any text');
        return;
      }

      final didTapOnExistingSelection = widget.textController.selection.isCollapsed
          ? tapTextPosition == _selectionBeforeSingleTapDown!.extent
          : tapTextPosition.offset >= _selectionBeforeSingleTapDown!.start &&
              tapTextPosition.offset <= _selectionBeforeSingleTapDown!.end;
      if (didTapOnExistingSelection) {
        // Toggle the toolbar display when the user taps on the collapsed caret,
        // or on top of an existing selection.
        _showToolbar = !_showToolbar;
      } else {
        // The user tapped somewhere in the text outside any existing selection.
        // Hide the toolbar.
        _showToolbar = false;
      }
    });
  }

  void _onDoubleTapDown(TapDownDetails details) {
    print('Double tap');
    widget.focusNode.requestFocus();

    // When the user released the first tap, the toolbar was set
    // to visible. At the beginning of a double-tap, make it invisible
    // again.
    setState(() {
      _showToolbar = false;
    });

    final tapTextPosition = _getTextPositionAtOffset(details.localPosition);
    if (tapTextPosition != null) {
      setState(() {
        final wordSelection = _getWordSelectionAt(tapTextPosition);

        widget.textController.selection = wordSelection;

        if (!wordSelection.isCollapsed) {
          _showToolbar = true;
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

    // Note: We add half a line height to the caret offset because the caret
    //       treats the top of the line as (0, 0). Without adding half the height,
    //       the user would have to drag an entire line down before the caret
    //       moves to the line below the current line.
    final startDragCaretOffset = widget.selectableTextKey.currentState!
            .getOffsetAtPosition(widget.textController.selection.extent) +
        Offset(
            0,
            (widget.selectableTextKey.currentState!.getLineHeightAtPosition(widget.textController.selection.extent) /
                2));

    setState(() {
      _handleDragMode = _HandleDragMode.collapsed;
      _dragOffset = details.localPosition;
      _startDragScrollOffset = widget.scrollKey.currentState!.scrollOffset;
    });
  }

  void _onBaseHandleDragStart(DragStartDetails details) {
    print('_onBaseHandleDragStart');

    setState(() {
      _showToolbar = false;
      _handleDragMode = _HandleDragMode.base;
      _startDragScrollOffset = widget.scrollKey.currentState!.scrollOffset;
      _dragOffset = (context.findRenderObject() as RenderBox).globalToLocal(details.globalPosition);
    });
  }

  void _onExtentHandleDragStart(DragStartDetails details) {
    print('_onExtentHandleDragStart()');

    scrollIfNearBoundary(details.globalPosition);

    setState(() {
      _showToolbar = false;
      _handleDragMode = _HandleDragMode.extent;
      _startDragScrollOffset = widget.scrollKey.currentState!.scrollOffset;
      _dragOffset = (context.findRenderObject() as RenderBox).globalToLocal(details.globalPosition);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    print('_onPanUpdate handle mode: $_handleDragMode, global position: ${details.globalPosition}');

    switch (_handleDragMode) {
      case _HandleDragMode.base:
        widget.textController.selection = widget.textController.selection.copyWith(
          baseOffset: _globalOffsetToTextPosition(details.globalPosition).offset,
        );
        break;
      case _HandleDragMode.extent:
        widget.textController.selection = widget.textController.selection.copyWith(
          extentOffset: _globalOffsetToTextPosition(details.globalPosition).offset,
        );
        break;
      case _HandleDragMode.collapsed:
      default:
        widget.textController.selection = TextSelection.collapsed(
          offset: _globalOffsetToTextPosition(details.globalPosition).offset,
        );
        break;
    }

    scrollIfNearBoundary(details.globalPosition);

    setState(() {
      _dragOffset = _dragOffset! + details.delta;
      _showMagnifier = true;
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
      case _HandleDragMode.collapsed:
        ensureSelectionIsVisible(true);
        break;
      case _HandleDragMode.base:
        ensureSelectionIsVisible(false);
        break;
      case _HandleDragMode.extent:
        ensureSelectionIsVisible(true);
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
      _showMagnifier = false;

      if (!widget.textController.selection.isCollapsed) {
        _showToolbar = true;
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
    if (_handleDragMode == _HandleDragMode.extent) {
      final newExtent = _getTextPositionAtOffset(_dragOffset!);
      widget.textController.selection = widget.textController.selection.copyWith(
        extentOffset: newExtent!.offset,
      );
    } else if (_handleDragMode == _HandleDragMode.base) {
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

  Offset get scrollOffset {
    if (widget.isMultiline) {
      return Offset(0, -widget.scrollController.offset);
    } else {
      return Offset(-widget.scrollController.offset, 0);
    }
  }

  Offset textOffsetToViewportOffset(Offset textOffset) {
    if (widget.isMultiline) {
      return textOffset.translate(0, -widget.scrollController.offset);
    } else {
      return textOffset.translate(-widget.scrollController.offset, 0);
    }
  }

  Offset viewportOffsetToTextOffset(Offset viewportOffset) {
    if (widget.isMultiline) {
      return viewportOffset.translate(0, widget.scrollController.offset);
    } else {
      return viewportOffset.translate(widget.scrollController.offset, 0);
    }
  }

  Offset _globalOffsetToTextOffset(Offset globalOffset) {
    final textBox = widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox;
    return textBox.globalToLocal(globalOffset);
  }

  TextPosition _globalOffsetToTextPosition(Offset globalOffset) {
    return widget.selectableTextKey.currentState!.getPositionNearestToOffset(
      _globalOffsetToTextOffset(globalOffset),
    );
  }

  SuperSelectableTextState get _text => widget.selectableTextKey.currentState!;

  void _onTextControllerChange() {
    // TODO: either bring this back or get rid of it
    // Use a post-frame callback to "ensure selection extent is visible"
    // so that any pending visual content changes can happen before
    // attempting to calculate the visual position of the selection extent.
    // WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
    //   if (mounted) {
    //     _ensureSelectionExtentIsVisible();
    //   }
    // });

    _rebuildHandles();
  }

  void ensureSelectionIsVisible(bool showExtent) {
    if (!widget.isMultiline) {
      _ensureSelectionIsVisibleInSingleLineTextField(showExtent);
    } else {
      _ensureSelectionIsVisibleInMultilineTextField(showExtent);
    }
  }

  void _ensureSelectionIsVisibleInSingleLineTextField(bool showExtent) {
    final selection = widget.textController.selection;
    if (selection.extentOffset == -1) {
      return;
    }

    final baseOrExtentOffset =
        showExtent ? _text.getOffsetAtPosition(selection.extent) : _text.getOffsetAtPosition(selection.base);

    const gutterExtent = 24; // _dragGutterExtent

    final myBox = context.findRenderObject() as RenderBox;
    final beyondLeftExtent = min(baseOrExtentOffset.dx - widget.scrollController.offset - gutterExtent, 0).abs();
    final beyondRightExtent =
        max(baseOrExtentOffset.dx - myBox.size.width - widget.scrollController.offset + gutterExtent, 0);

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

  void _ensureSelectionIsVisibleInMultilineTextField(bool showExtent) {
    final selection = widget.textController.selection;
    if (selection.extentOffset == -1) {
      return;
    }

    final textPosition = showExtent ? selection.extent : selection.base;
    final baseOrExtentOffset =
        showExtent ? _text.getOffsetAtPosition(textPosition) : _text.getOffsetAtPosition(textPosition);

    const gutterExtent = 0; // _dragGutterExtent
    final lineHeight = widget.selectableTextKey.currentState!.getLineHeightAtPosition(textPosition);
    final extentLineIndex = (baseOrExtentOffset.dy / lineHeight).round();

    final myBox = context.findRenderObject() as RenderBox;
    final beyondTopExtent = min<double>(baseOrExtentOffset.dy - widget.scrollController.offset - gutterExtent, 0).abs();
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
    _log.log('_ensureSelectionExtentIsVisible', ' - extent rect: $baseOrExtentOffset');
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

  void scrollIfNearBoundary(Offset focalPointInGlobalCoords) {
    if (widget.isMultiline) {
      scrollIfNearVerticalBoundary(focalPointInGlobalCoords);
    } else {
      scrollIfNearHorizontalBoundary(focalPointInGlobalCoords);
    }
  }

  void scrollIfNearHorizontalBoundary(Offset focalPointInGlobalCoords) {
    final textFieldBox = context.findRenderObject() as RenderBox;
    final textFieldViewportOffset = textFieldBox.globalToLocal(focalPointInGlobalCoords);
    // print('_scrollIfNearHorizontalBoundary: $textFieldViewportOffset');
    if (textFieldViewportOffset.dx < _singleLineFieldAutoScrollGap) {
      // print('Drag offset is near start. Scrolling left');
      startScrollingToStart(amountPerFrame: 2);
    } else if (textFieldViewportOffset.dx > (textFieldBox.size.width - _singleLineFieldAutoScrollGap)) {
      // print('Drag offset is near end. Scrolling right');
      startScrollingToEnd(amountPerFrame: 2);
    } else {
      // print('Stopping auto-scrolling');
      stopScrolling();
    }
  }

  void scrollIfNearVerticalBoundary(Offset focalPointInGlobalCoords) {
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
      startScrollingToStart(amountPerFrame: 2);
    } else if (textFieldViewportOffset.dy > (textFieldViewportBox.size.height - _mulitlineFieldAutoScrollGap)) {
      // print('Drag offset is near end. Scrolling down');
      startScrollingToEnd(amountPerFrame: 2);
    } else {
      stopScrolling();
    }
  }

  void startScrollingToStart({required double amountPerFrame}) {
    assert(amountPerFrame > 0);

    if (_scrollToStartOnTick) {
      _scrollAmountPerFrame = amountPerFrame;
      return;
    }

    _scrollToStartOnTick = true;
    _ticker.start();
  }

  void stopScrollingToStart() {
    if (!_scrollToStartOnTick) {
      return;
    }

    _scrollToStartOnTick = false;
    _scrollAmountPerFrame = 0;
    _ticker.stop();
  }

  void scrollToStart() {
    if (widget.scrollController.offset <= 0) {
      stopScrollingToStart();
      return;
    }

    widget.scrollController.jumpTo(widget.scrollController.offset - _scrollAmountPerFrame);
  }

  void startScrollingToEnd({required double amountPerFrame}) {
    assert(amountPerFrame > 0);

    if (_scrollToEndOnTick) {
      _scrollAmountPerFrame = amountPerFrame;
      return;
    }

    _scrollToEndOnTick = true;
    _ticker.start();
  }

  void stopScrollingToEnd() {
    if (!_scrollToEndOnTick) {
      return;
    }

    _scrollToEndOnTick = false;
    _scrollAmountPerFrame = 0;
    _ticker.stop();
  }

  void stopScrolling() {
    stopScrollingToStart();
    stopScrollingToEnd();
  }

  void scrollToEnd() {
    if (widget.scrollController.offset >= widget.scrollController.position.maxScrollExtent) {
      stopScrollingToEnd();
      return;
    }

    widget.scrollController.jumpTo(widget.scrollController.offset + _scrollAmountPerFrame);
  }

  void _onTick(elapsedTime) {
    if (_scrollToStartOnTick) {
      scrollToStart();
    }
    if (_scrollToEndOnTick) {
      scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _textContentOffsetLink,
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
        onDoubleTap: () {
          // no-op
        },
        child: Container(
          decoration: BoxDecoration(
            border: widget.showDebugPaint ? Border.all(color: Colors.purple) : const Border(),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildScrollView(child: widget.child),
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
                          ..onEnd = _onPanEnd
                          ..onCancel = _onPanCancel;
                      },
                    ),
                  },
                  child: Stack(
                    children: [
                      if (widget.textController.selection.extentOffset >= 0) _buildExtentTrackerForMagnifier(),
                    ],
                  ),
                ),
              ),
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

  Widget _buildExtentTrackerForMagnifier() {
    if (_handleDragMode == null) {
      return const SizedBox();
    }

    // Apply any scrolling that has occurred during this drag session.
    //
    // When the user drags near a scrolling boundary, scrolling automatically
    // occurs. This means that the content is moving while the user's pointer
    // remains in the same place, thus no drag callback gets invoked. For this
    // reason, we need to rebuild when scrolling occurs, and we need to apply
    // the difference between the scroll offset when the user started dragging
    // vs the scroll offset right now.
    final currentScrollOffset = widget.scrollKey.currentState!.scrollOffset;
    final scrolledDragOffset = _dragOffset! + (_startDragScrollOffset! - currentScrollOffset);

    // print('----');
    // print('Current drag offset: $_dragOffset');
    // print('Start scroll offset: $_startDragScrollOffset');
    // print('Current scroll offset: $currentScrollOffset');
    // print('Extent tracker offset: $scrolledDragOffset');
    // print('----');
    return Positioned(
      // left: scrolledDragOffset.dx,
      // top: scrolledDragOffset.dy,
      left: _dragOffset!.dx,
      top: _dragOffset!.dy,
      child: CompositedTransformTarget(
        link: _draggingHandleLink,
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

class EditingControls extends StatefulWidget {
  const EditingControls({
    Key? key,
    required this.textFieldViewportKey,
    required this.selectableTextKey,
    required this.textFieldLayerLink,
    required this.textContentOffsetLink,
    required this.scrollKey,
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

  final GlobalKey textFieldViewportKey;
  final LayerLink textFieldLayerLink;
  final LayerLink textContentOffsetLink;
  final GlobalKey<SuperSelectableTextState> selectableTextKey;
  final GlobalKey<IOSTextfieldInteractorState> scrollKey;
  final TextSelection selection;
  final bool showToolbar;
  final bool showMagnifier;
  final _HandleDragMode? handleDragMode;
  final LayerLink? draggingHandleLink;
  final Color handleColor;
  final bool showDebugPaint;
  final Function(DragStartDetails details) onBaseHandleDragStart;
  final Function(DragStartDetails details) onExtentHandleDragStart;
  final Function(DragUpdateDetails details) onPanUpdate;
  final Function(DragEndDetails details) onPanEnd;
  final VoidCallback onPanCancel;

  @override
  _EditingControlsState createState() => _EditingControlsState();
}

class _EditingControlsState extends State<EditingControls> {
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
    final textFieldBox = textFieldRenderObject as RenderBox;
    final textFieldGlobalOffset = textFieldBox.localToGlobal(Offset.zero);

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
      final extentOffsetInViewport = widget.scrollKey.currentState!.textOffsetToViewportOffset(extentOffsetInText);
      toolbarTopAnchor = extentOffsetInViewport - const Offset(0, toolbarGap);
      toolbarBottomAnchor = extentOffsetInViewport + const Offset(0, 20 + toolbarGap); // TODO: use real line height
    } else {
      final selectionBoxes = widget.selectableTextKey.currentState!.getBoxesForSelection(widget.selection);
      Rect selectionBounds = selectionBoxes.first.toRect();
      for (int i = 1; i < selectionBoxes.length; ++i) {
        selectionBounds = selectionBounds.expandToInclude(selectionBoxes[i].toRect());
      }
      final selectionTopInText = selectionBounds.topCenter;
      final selectionTopInViewport = widget.scrollKey.currentState!.textOffsetToViewportOffset(selectionTopInText);
      toolbarTopAnchor = selectionTopInViewport - const Offset(0, toolbarGap);

      final selectionBottomInText = selectionBounds.bottomCenter;
      final selectionBottomInViewport =
          widget.scrollKey.currentState!.textOffsetToViewportOffset(selectionBottomInText);
      toolbarBottomAnchor = selectionBottomInViewport + const Offset(0, 20 + toolbarGap);
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
    toolbarTopAnchor = Offset(
      toolbarTopAnchor.dx,
      min(
        toolbarTopAnchor.dy,
        toolbarGap,
      ),
    );

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
        widget.handleDragMode != _HandleDragMode.base &&
        widget.handleDragMode != _HandleDragMode.extent) {
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
      final textFieldGlobalOffset = textFieldBox.localToGlobal(Offset.zero);
      final textFieldRect = Offset.zero & textFieldBox.size;

      final selectableTextBox = widget.selectableTextKey.currentContext!.findRenderObject() as RenderBox;

      const estimatedHandleVisualSize = Size(24, 24);

      final upstreamCaretGlobalOffset = selectableTextBox.localToGlobal(upstreamCaretOffset) - const Offset(-12, -5);
      final estimatedBaseHandleRect = upstreamCaretOffset & estimatedHandleVisualSize;

      final downstreamCaretGlobalOffset =
          selectableTextBox.localToGlobal(downstreamCaretOffset) - const Offset(-12, -5);
      final estimatedExtentHandleRect = downstreamCaretOffset & estimatedHandleVisualSize;

      showBaseHandle = _isDraggingBase ||
          widget.handleDragMode == _HandleDragMode.base ||
          textFieldRect.overlaps(estimatedBaseHandleRect);
      showExtentHandle = _isDraggingExtent ||
          widget.handleDragMode == _HandleDragMode.extent ||
          textFieldRect.overlaps(estimatedExtentHandleRect);

      // print('TextField Rect: $textFieldRect');
      // print('Base handle Rect: $estimatedBaseHandleRect');
      // print('Extent handle Rect: $estimatedExtentHandleRect');
    }

    if (!showExtentHandle) {
      print('Hiding extent handle');
    }

    // print('Upstream caret viewport offset: $upstreamCaretOffset');
    // print('Downstream caret viewport offset: $downstreamCaretOffset');
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
    final desiredAnchor = fitsAboveTextField ? desiredTopAnchorInTextField : desiredBottomAnchorInTextField;

    final desiredTopLeft = desiredAnchor - Offset(childSize.width / 2, childSize.height);

    double x = max(desiredTopLeft.dx, -textFieldGlobalOffset.dx);
    x = min(x, size.width - childSize.width - textFieldGlobalOffset.dx);

    // TODO: constrain the y-value

    final constrainedOffset = Offset(x, desiredTopLeft.dy);

    // print('ToolbarPositionDelegate:');
    // print(' - available space: $size');
    // print(' - child size: $childSize');
    // print(' - text field offset: $textFieldGlobalOffset');
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

enum _HandleDragMode {
  collapsed,
  base,
  extent,
}

enum _HandleType {
  none,
  left,
  right,
}
