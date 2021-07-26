import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';

import '../../super_selectable_text.dart';
import '../super_textfield.dart';

// TODO: convert to newer logger
final _log = Logger(scope: 'IOSTextField scrolling');

/// Handles all scrolling behavior for a text field.
///
/// [SuperTextFieldScrollview] is intended to operate as a piece within
/// a larger composition that behaves as a text field. [SuperTextFieldScrollview]
/// is defined on its own so that it can be replaced with a widget that handles
/// scrolling differently.
///
/// [SuperTextFieldScrollview] determines when and where to scroll by working
/// with a corresponding [SuperSelectableText] widget that is tied to [textKey].
class SuperTextFieldScrollview extends StatefulWidget {
  const SuperTextFieldScrollview({
    Key? key,
    required this.textKey,
    required this.textController,
    required this.scrollController,
    required this.padding,
    required this.viewportHeight,
    required this.estimatedLineHeight,
    required this.isMultiline,
    this.showDebugPaint = false,
    required this.child,
  }) : super(key: key);

  /// [TextController] for the text/selection within this text field.
  final AttributedTextEditingController textController;

  /// [GlobalKey] that links this [SuperTextFieldScrollview] to
  /// the [SuperSelectableText] widget that paints the text for this text field.
  final GlobalKey<SuperSelectableTextState> textKey;

  /// [ScrollController] that controls the scroll offset of this [SuperTextFieldScrollview].
  final ScrollController scrollController;

  /// Padding placed around the text content of this text field, but within the
  /// scrollable viewport.
  final EdgeInsetsGeometry padding;

  /// The height of the viewport for this text field.
  ///
  /// If [null] then the viewport is permitted to grow/shrink to any desired height.
  final double? viewportHeight;

  /// An estimate for the height in pixels of a single line of text within this
  /// text field.
  final double estimatedLineHeight;

  /// Whether or not this text field allows multiple lines of text.
  final bool isMultiline;

  /// Whether to paint various guides for debugging purposes.
  final bool showDebugPaint;

  /// The rest of the subtree for this text field.
  final Widget child;

  @override
  SuperTextFieldScrollviewState createState() => SuperTextFieldScrollviewState();
}

class SuperTextFieldScrollviewState extends State<SuperTextFieldScrollview> with SingleTickerProviderStateMixin {
  bool _scrollToStartOnTick = false;
  bool _scrollToEndOnTick = false;
  double _scrollAmountPerFrame = 0;
  late Ticker _ticker;
  final _scrollChangeListeners = <VoidCallback>{};

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);

    widget.textController.addListener(_onSelectionOrContentChange);

    widget.scrollController.addListener(_onScrollChange);
  }

  @override
  void didUpdateWidget(SuperTextFieldScrollview oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.textController != oldWidget.textController) {
      oldWidget.textController.removeListener(_onSelectionOrContentChange);
      widget.textController.addListener(_onSelectionOrContentChange);
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
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScrollChange);
    _scrollChangeListeners.clear();
    _ticker.dispose();
    super.dispose();
  }

  void addScrollListener(VoidCallback callback) {
    _scrollChangeListeners.add(callback);
  }

  void removeScrollListener(VoidCallback callback) {
    _scrollChangeListeners.remove(callback);
  }

  void _onScrollChange() {
    print('scrolling: _onScrollChange');
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

  Offset viewportOffsetToTextOffset(Offset textOffset) {
    if (widget.isMultiline) {
      return textOffset.translate(0, widget.scrollController.offset);
    } else {
      return textOffset.translate(widget.scrollController.offset, 0);
    }
  }

  SuperSelectableTextState get _text => widget.textKey.currentState!;

  void _onSelectionOrContentChange() {
    // TODO: either bring this back or get rid of it
    // Use a post-frame callback to "ensure selection extent is visible"
    // so that any pending visual content changes can happen before
    // attempting to calculate the visual position of the selection extent.
    // WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
    //   if (mounted) {
    //     _ensureSelectionExtentIsVisible();
    //   }
    // });
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
    final beyondRightExtent = max(
        baseOrExtentOffset.dx -
            myBox.size.width -
            widget.scrollController.offset +
            gutterExtent +
            widget.padding.horizontal,
        0);

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

    final baseOrExtentOffset =
        showExtent ? _text.getOffsetAtPosition(selection.extent) : _text.getOffsetAtPosition(selection.base);

    const gutterExtent = 0; // _dragGutterExtent
    final extentLineIndex = (baseOrExtentOffset.dy / widget.estimatedLineHeight).round();

    final myBox = context.findRenderObject() as RenderBox;
    final beyondTopExtent = min<double>(baseOrExtentOffset.dy - widget.scrollController.offset - gutterExtent, 0).abs();
    final beyondBottomExtent = max<double>(
        ((extentLineIndex + 1) * widget.estimatedLineHeight) -
            myBox.size.height -
            widget.scrollController.offset +
            gutterExtent +
            (widget.estimatedLineHeight / 2) + // manual adjustment to avoid line getting half cut off
            widget.padding.vertical / 2,
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

  void scrollToEnd() {
    if (widget.scrollController.offset >= widget.scrollController.position.maxScrollExtent) {
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
    return SizedBox(
      height: widget.viewportHeight,
      child: Stack(
        children: [
          SingleChildScrollView(
            controller: widget.scrollController,
            physics: const NeverScrollableScrollPhysics(),
            scrollDirection: widget.isMultiline ? Axis.vertical : Axis.horizontal,
            child: Padding(
              padding: widget.padding,
              child: widget.child,
            ),
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
              height: 20,
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
              height: 20,
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
            width: 20,
            color: Colors.purpleAccent.withOpacity(0.5),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Container(
            width: 20,
            color: Colors.purpleAccent.withOpacity(0.5),
          ),
        ),
      ];
    }
  }
}
