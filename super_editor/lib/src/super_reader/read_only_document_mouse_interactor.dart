import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/default_editor/document_scrollable.dart';
import 'package:super_editor/src/document_operations/selection_operations.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/document_gestures_interaction_overrides.dart';
import 'package:super_editor/src/infrastructure/flutter/flutter_scheduler.dart';
import 'package:super_editor/src/infrastructure/multi_tap_gesture.dart';
import 'package:super_editor/src/infrastructure/sliver_hybrid_stack.dart';

import 'reader_context.dart';

/// Governs mouse gesture interaction with a read-only document, such as scrolling
/// a document with a scroll wheel and tap-and-dragging to create an expanded selection.

/// Document gesture interactor that's designed for read-only mouse input,
/// e.g., drag to select, and mouse wheel to scroll.
///
///  - selects content on double, and triple taps
///  - selects content on drag, after single, double, or triple tap
///  - scrolls with the mouse wheel
///  - automatically scrolls up or down when the user drags near
///    a boundary
///
/// The primary difference between a read-only mouse interactor, and an
/// editing mouse interactor, is that read-only documents don't support
/// collapsed selections, i.e., caret display. When the user taps on
/// a read-only document, nothing happens. The user must drag an expanded
/// selection, or double/triple tap to select content.
class ReadOnlyDocumentMouseInteractor extends StatefulWidget {
  const ReadOnlyDocumentMouseInteractor({
    Key? key,
    this.focusNode,
    required this.readerContext,
    this.contentTapHandler,
    required this.autoScroller,
    required this.fillViewport,
    this.showDebugPaint = false,
    required this.child,
  }) : super(key: key);

  final FocusNode? focusNode;

  /// Service locator for document dependencies.
  final SuperReaderContext readerContext;

  /// Optional handler that responds to taps on content, e.g., opening
  /// a link when the user taps on text with a link attribution.
  final ContentTapDelegate? contentTapHandler;

  /// Auto-scrolling delegate.
  final AutoScrollController autoScroller;

  final bool fillViewport;

  /// Paints some extra visual ornamentation to help with
  /// debugging, when `true`.
  final bool showDebugPaint;

  /// The document to display within this [ReadOnlyDocumentMouseInteractor].
  final Widget child;

  @override
  State createState() => _ReadOnlyDocumentMouseInteractorState();
}

class _ReadOnlyDocumentMouseInteractorState extends State<ReadOnlyDocumentMouseInteractor>
    with SingleTickerProviderStateMixin {
  final _documentWrapperKey = GlobalKey();

  late FocusNode _focusNode;

  // Tracks user drag gestures for selection purposes.
  SelectionType _selectionType = SelectionType.position;
  Offset? _dragStartGlobal;
  Offset? _dragEndGlobal;
  bool _expandSelectionDuringDrag = false;

  /// Holds which kind of device started a pan gesture, e.g., a mouse or a trackpad.
  PointerDeviceKind? _panGestureDevice;

  final _mouseCursor = ValueNotifier<MouseCursor>(SystemMouseCursors.text);
  Offset? _lastHoverOffset;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    widget.readerContext.selection.addListener(_onSelectionChange);
    widget.autoScroller
      ..addListener(_updateDragSelection)
      ..addListener(_updateMouseCursorAtLatestOffset);
    widget.contentTapHandler?.addListener(_updateMouseCursorAtLatestOffset);
  }

  @override
  void didUpdateWidget(ReadOnlyDocumentMouseInteractor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (widget.readerContext.selection != oldWidget.readerContext.selection) {
      oldWidget.readerContext.selection.removeListener(_onSelectionChange);
      widget.readerContext.selection.addListener(_onSelectionChange);
    }
    if (widget.autoScroller != oldWidget.autoScroller) {
      oldWidget.autoScroller
        ..removeListener(_updateDragSelection)
        ..removeListener(_updateMouseCursorAtLatestOffset);
      widget.autoScroller
        ..addListener(_updateDragSelection)
        ..addListener(_updateMouseCursorAtLatestOffset);
    }
    if (widget.contentTapHandler != oldWidget.contentTapHandler) {
      oldWidget.contentTapHandler?.removeListener(_updateMouseCursorAtLatestOffset);
      widget.contentTapHandler?.addListener(_updateMouseCursorAtLatestOffset);
    }
  }

  @override
  void dispose() {
    widget.contentTapHandler?.removeListener(_updateMouseCursorAtLatestOffset);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    widget.readerContext.selection.removeListener(_onSelectionChange);
    widget.autoScroller
      ..removeListener(_updateDragSelection)
      ..removeListener(_updateMouseCursorAtLatestOffset);
    super.dispose();
  }

  /// Returns the layout for the current document, which answers questions
  /// about the locations and sizes of visual components within the layout.
  DocumentLayout get _docLayout => widget.readerContext.documentLayout;

  Offset _getDocOffsetFromGlobalOffset(Offset globalOffset) {
    return _docLayout.getDocumentOffsetFromAncestorOffset(globalOffset);
  }

  bool get _isShiftPressed => (HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight) ||
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shift));

  void _onSelectionChange() {
    if (mounted) {
      // Use a post-frame callback to "ensure selection extent is visible"
      // so that any pending visual document changes can happen before
      // attempting to calculate the visual position of the selection extent.
      onNextFrame((_) {
        readerGesturesLog.finer("Ensuring selection extent is visible because the doc selection changed");

        final globalExtentRect = _getSelectionExtentAsGlobalRect();
        if (globalExtentRect != null) {
          widget.autoScroller.ensureGlobalRectIsVisible(globalExtentRect);
        }
      });
    }
  }

  Rect? _getSelectionExtentAsGlobalRect() {
    final selection = widget.readerContext.selection.value;
    if (selection == null) {
      return null;
    }

    // The reason that a Rect is used instead of an Offset is
    // because things like Images and Horizontal Rules don't have
    // a clear selection offset. They are either entirely selected,
    // or not selected at all.
    final selectionExtentRectInDoc = _docLayout.getRectForPosition(
      selection.extent,
    );
    if (selectionExtentRectInDoc == null) {
      readerGesturesLog.warning(
          "Tried to ensure that position ${selection.extent} is visible on screen but no bounding box was returned for that position.");
      return null;
    }

    final globalTopLeft = _docLayout.getGlobalOffsetFromDocumentOffset(selectionExtentRectInDoc.topLeft);
    return Rect.fromLTWH(
        globalTopLeft.dx, globalTopLeft.dy, selectionExtentRectInDoc.width, selectionExtentRectInDoc.height);
  }

  void _onMouseMove(PointerHoverEvent event) {
    _updateMouseCursor(event.position);
    _lastHoverOffset = event.position;
  }

  void _updateMouseCursorAtLatestOffset() {
    if (_lastHoverOffset == null) {
      return;
    }
    _updateMouseCursor(_lastHoverOffset!);
  }

  void _updateMouseCursor(Offset globalPosition) {
    final docOffset = _getDocOffsetFromGlobalOffset(globalPosition);
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    if (docPosition == null) {
      _mouseCursor.value = SystemMouseCursors.text;
      return;
    }

    final cursorForContent = widget.contentTapHandler?.mouseCursorForContentHover(docPosition);
    _mouseCursor.value = cursorForContent ?? SystemMouseCursors.text;
  }

  void _onTapUp(TapUpDetails details) {
    readerGesturesLog.info("Tap up on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    readerGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    readerGesturesLog.fine(" - tapped document position: $docPosition");

    _focusNode.requestFocus();

    if (docPosition == null) {
      readerGesturesLog.fine("No document content at ${details.globalPosition}.");
      widget.readerContext.selection.value = null;
      return;
    }

    if (widget.contentTapHandler != null) {
      final result = widget.contentTapHandler!.onTap(docPosition);
      if (result == TapHandlingInstruction.halt) {
        // The custom tap handler doesn't want us to react at all
        // to the tap.
        return;
      }
    }

    final expandSelection = _isShiftPressed && widget.readerContext.selection.value != null;
    if (!expandSelection) {
      // Read-only documents don't show carets. Therefore, we only care about
      // a tap when we're expanding an existing selection.
      widget.readerContext.selection.value = null;
      _selectionType = SelectionType.position;
      return;
    }

    final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
    if (!tappedComponent.isVisualSelectionSupported()) {
      moveToNearestSelectableComponent(
        widget.readerContext.document,
        widget.readerContext.documentLayout,
        widget.readerContext.selection,
        docPosition.nodeId,
        tappedComponent,
      );
      return;
    }

    // The user tapped while pressing shift and there's an existing
    // selection. Move the extent of the selection to where the user tapped.
    widget.readerContext.selection.value = widget.readerContext.selection.value!.copyWith(
      extent: docPosition,
    );
  }

  void _onDoubleTapDown(TapDownDetails details) {
    readerGesturesLog.info("Double tap down on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    readerGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    readerGesturesLog.fine(" - tapped document position: $docPosition");

    final tappedComponent = docPosition != null ? _docLayout.getComponentByNodeId(docPosition.nodeId)! : null;
    if (tappedComponent != null && !tappedComponent.isVisualSelectionSupported()) {
      // The user double tapped on a component that should never display itself
      // as selected. Therefore, we ignore this double-tap.
      return;
    }

    if (docPosition != null && widget.contentTapHandler != null) {
      final result = widget.contentTapHandler!.onDoubleTap(docPosition);
      if (result == TapHandlingInstruction.halt) {
        // The custom tap handler doesn't want us to react at all
        // to the tap.
        return;
      }
    }

    _selectionType = SelectionType.word;
    widget.readerContext.selection.value = null;

    if (docPosition != null) {
      bool didSelectContent = selectWordAt(
        docPosition: docPosition,
        docLayout: _docLayout,
        selection: widget.readerContext.selection,
      );

      if (!didSelectContent) {
        didSelectContent = selectBlockAt(docPosition, widget.readerContext.selection);
      }

      if (!didSelectContent) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  void _onDoubleTap() {
    readerGesturesLog.info("Double tap up on document");
    _selectionType = SelectionType.position;
  }

  void _onTripleTapDown(TapDownDetails details) {
    readerGesturesLog.info("Triple down down on document");
    final docOffset = _getDocOffsetFromGlobalOffset(details.globalPosition);
    readerGesturesLog.fine(" - document offset: $docOffset");
    final docPosition = _docLayout.getDocumentPositionNearestToOffset(docOffset);
    readerGesturesLog.fine(" - tapped document position: $docPosition");

    if (docPosition != null && widget.contentTapHandler != null) {
      final result = widget.contentTapHandler!.onTripleTap(docPosition);
      if (result == TapHandlingInstruction.halt) {
        // The custom tap handler doesn't want us to react at all
        // to the tap.
        return;
      }
    }

    if (docPosition != null) {
      final tappedComponent = _docLayout.getComponentByNodeId(docPosition.nodeId)!;
      if (!tappedComponent.isVisualSelectionSupported()) {
        return;
      }
    }

    _selectionType = SelectionType.paragraph;
    widget.readerContext.selection.value = null;

    if (docPosition != null) {
      final didSelectParagraph = selectParagraphAt(
        docPosition: docPosition,
        docLayout: _docLayout,
        selection: widget.readerContext.selection,
      );
      if (!didSelectParagraph) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  void _onTripleTap() {
    readerGesturesLog.info("Triple tap up on document");
    _selectionType = SelectionType.position;
  }

  void _selectPosition(DocumentPosition position) {
    readerGesturesLog.fine("Setting document selection to $position");
    widget.readerContext.selection.value = DocumentSelection.collapsed(
      position: position,
    );
  }

  void _onPanStart(DragStartDetails details) {
    readerGesturesLog.info("Pan start on document, global offset: ${details.globalPosition}, device: ${details.kind}");

    _panGestureDevice = details.kind;

    if (_panGestureDevice == PointerDeviceKind.trackpad) {
      // After flutter 3.3, dragging with two fingers on a trackpad triggers a pan gesture.
      // This gesture should scroll the document and keep the selection unchanged.
      return;
    }

    _dragStartGlobal = details.globalPosition;

    widget.autoScroller.enableAutoScrolling();

    if (_isShiftPressed) {
      _expandSelectionDuringDrag = true;
    }

    if (!_isShiftPressed) {
      // Only clear the selection if the user isn't pressing shift. Shift is
      // used to expand the current selection, not replace it.
      readerGesturesLog.fine("Shift isn't pressed. Clearing any existing selection before panning.");
      widget.readerContext.selection.value = null;
    }

    _focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    readerGesturesLog
        .info("Pan update on document, global offset: ${details.globalPosition}, device: $_panGestureDevice");

    setState(() {
      _dragEndGlobal = details.globalPosition;

      _updateDragSelection();

      widget.autoScroller.setGlobalAutoScrollRegion(
        Rect.fromLTWH(_dragEndGlobal!.dx, _dragEndGlobal!.dy, 1, 1),
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    readerGesturesLog.info("Pan end on document, device: $_panGestureDevice");

    if (_panGestureDevice == PointerDeviceKind.trackpad) {
      // The user ended a pan gesture with two fingers on a trackpad.
      // We already scrolled the document.
      widget.autoScroller.goBallistic(-details.velocity.pixelsPerSecond.dy);
      return;
    }
    _onDragEnd();
  }

  void _onPanCancel() {
    readerGesturesLog.info("Pan cancel on document");
    _onDragEnd();
  }

  void _onDragEnd() {
    setState(() {
      _dragStartGlobal = null;
      _dragEndGlobal = null;
      _expandSelectionDuringDrag = false;
    });

    widget.autoScroller.disableAutoScrolling();
  }

  void _updateDragSelection() {
    if (_dragEndGlobal == null) {
      // User isn't dragging. No need to update drag selection.
      return;
    }

    final dragStartInDoc =
        _getDocOffsetFromGlobalOffset(_dragStartGlobal!) + Offset(0, widget.autoScroller.deltaWhileAutoScrolling);
    final dragEndInDoc = _getDocOffsetFromGlobalOffset(_dragEndGlobal!);
    readerGesturesLog.finest(
      '''
Updating drag selection:
 - drag start in doc: $dragStartInDoc
 - drag end in doc: $dragEndInDoc''',
    );

    selectRegion(
      documentLayout: _docLayout,
      baseOffsetInDocument: dragStartInDoc,
      extentOffsetInDocument: dragEndInDoc,
      selectionType: _selectionType,
      expandSelection: _expandSelectionDuringDrag,
      selection: widget.readerContext.selection,
    );

    if (widget.showDebugPaint) {
      setState(() {
        // Repaint the debug UI.
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SliverHybridStack(
      fillViewport: widget.fillViewport,
      children: [
        Listener(
          onPointerHover: _onMouseMove,
          child: _buildCursorStyle(
            child: _buildGestureInput(
              child: _buildDocumentContainer(
                document: const SizedBox(),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }

  Widget _buildCursorStyle({
    required Widget child,
  }) {
    return ValueListenableBuilder(
      valueListenable: _mouseCursor,
      builder: (context, value, child) {
        return MouseRegion(
          cursor: _mouseCursor.value,
          onExit: (_) => _lastHoverOffset = null,
          child: child,
        );
      },
      child: child,
    );
  }

  Widget _buildGestureInput({
    required Widget child,
  }) {
    final gestureSettings = MediaQuery.maybeOf(context)?.gestureSettings;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        TapSequenceGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapSequenceGestureRecognizer>(
          () => TapSequenceGestureRecognizer(),
          (TapSequenceGestureRecognizer recognizer) {
            recognizer
              ..onTapUp = _onTapUp
              ..onDoubleTapDown = _onDoubleTapDown
              ..onDoubleTap = _onDoubleTap
              ..onTripleTapDown = _onTripleTapDown
              ..onTripleTap = _onTripleTap
              ..gestureSettings = gestureSettings;
          },
        ),
        PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
          () => PanGestureRecognizer(supportedDevices: {
            PointerDeviceKind.mouse,
            PointerDeviceKind.touch,
          }),
          (PanGestureRecognizer recognizer) {
            recognizer
              ..onStart = _onPanStart
              ..onUpdate = _onPanUpdate
              ..onEnd = _onPanEnd
              ..onCancel = _onPanCancel
              ..gestureSettings = gestureSettings;
          },
        ),
      },
      child: child,
    );
  }

  Widget _buildDocumentContainer({
    required Widget document,
  }) {
    return Align(
      alignment: Alignment.topCenter,
      child: Stack(
        children: [
          SizedBox(
            key: _documentWrapperKey,
            child: document,
          ),
          if (widget.showDebugPaint) //
            ..._buildDebugPaintInDocSpace(),
        ],
      ),
    );
  }

  List<Widget> _buildDebugPaintInDocSpace() {
    final dragStartInDoc = _dragStartGlobal != null
        ? _getDocOffsetFromGlobalOffset(_dragStartGlobal!) + Offset(0, widget.autoScroller.deltaWhileAutoScrolling)
        : null;
    final dragEndInDoc = _dragEndGlobal != null ? _getDocOffsetFromGlobalOffset(_dragEndGlobal!) : null;

    return [
      if (dragStartInDoc != null)
        Positioned(
          left: dragStartInDoc.dx,
          top: dragStartInDoc.dy,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF0088FF),
              ),
            ),
          ),
        ),
      if (dragEndInDoc != null)
        Positioned(
          left: dragEndInDoc.dx,
          top: dragEndInDoc.dy,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF0088FF),
              ),
            ),
          ),
        ),
      if (dragStartInDoc != null && dragEndInDoc != null)
        Positioned(
          left: min(dragStartInDoc.dx, dragEndInDoc.dx),
          top: min(dragStartInDoc.dy, dragEndInDoc.dy),
          width: (dragEndInDoc.dx - dragStartInDoc.dx).abs(),
          height: (dragEndInDoc.dy - dragStartInDoc.dy).abs(),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF0088FF), width: 3),
            ),
          ),
        ),
    ];
  }
}
