import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/default_editor/super_editor.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';
import 'package:super_editor/src/infrastructure/super_textfield/ios/_editing_controls.dart';

import '../../attributed_text.dart';
import '../../super_selectable_text.dart';
import '../super_textfield.dart' hide SuperTextFieldScrollview, SuperTextFieldScrollviewState;
import '_caret.dart';
import '_floating_cursor.dart';
import '_user_interaction.dart';

export '_caret.dart';
export '_handles.dart';
export '_magnifier.dart';
export '_toolbar.dart';
export '_user_interaction.dart';

class SuperIOSTextfield extends StatefulWidget {
  const SuperIOSTextfield({
    Key? key,
    this.focusNode,
    this.textController,
    required this.selectionColor,
    required this.controlsColor,
    this.textStyleBuilder = defaultStyleBuilder,
    this.minLines,
    this.maxLines = 1,
    this.padding = EdgeInsets.zero,
    this.textInputAction = TextInputAction.done,
    this.showDebugPaint = false,
    this.onPerformActionPressed,
  }) : super(key: key);

  final FocusNode? focusNode;

  final AttributedTextEditingController? textController;

  final AttributionStyleBuilder textStyleBuilder;

  final Color selectionColor;

  final Color controlsColor;

  final int? minLines;
  final int? maxLines;

  final EdgeInsets padding;

  final TextInputAction textInputAction;

  final bool showDebugPaint;

  /// Callback invoked when the user presses the "action" button
  /// on the keyboard, e.g., "done", "call", "emergency", etc.
  final Function(TextInputAction)? onPerformActionPressed;

  @override
  _SuperIOSTextfieldState createState() => _SuperIOSTextfieldState();
}

class _SuperIOSTextfieldState extends State<SuperIOSTextfield> implements TextInputClient {
  final _textFieldKey = GlobalKey();
  final _textFieldLayerLink = LayerLink();
  final _scrollKey = GlobalKey<IOSTextfieldInteractorState>();
  final _textKey = GlobalKey<SuperSelectableTextState>();

  late FocusNode _focusNode;

  late AttributedTextEditingController _textEditingController;
  late FloatingCursorController _floatingCursorController;
  TextInputConnection? _textInputConnection;

  final _magnifierLayerLink = LayerLink();
  late IOSEditingOverlayController _editingOverlayController;

  bool _needViewportHeight = true;
  double? _viewportHeight;
  ScrollController _scrollController = ScrollController(); // TODO: allow ScrollController in widget

  @override
  void initState() {
    super.initState();
    _focusNode = (widget.focusNode ?? FocusNode())
      ..unfocus()
      ..addListener(_onFocusChange);

    _textEditingController = (widget.textController ?? AttributedTextEditingController())
      ..addListener(_sendEditingValueToPlatform);

    _floatingCursorController = FloatingCursorController(textController: _textEditingController);

    _editingOverlayController = IOSEditingOverlayController(magnifierFocalPoint: _magnifierLayerLink);
  }

  @override
  void didUpdateWidget(SuperIOSTextfield oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_onFocusChange);
      if (widget.focusNode != null) {
        _focusNode = widget.focusNode!;
      } else {
        _focusNode = FocusNode();
      }
      _focusNode.addListener(_onFocusChange);
    }

    if (widget.textInputAction != oldWidget.textInputAction && _textInputConnection != null) {
      _textInputConnection!.updateConfig(TextInputConfiguration(
        inputAction: widget.textInputAction,
      ));
    }

    if (widget.textController != oldWidget.textController) {
      _textEditingController.removeListener(_sendEditingValueToPlatform);
      if (widget.textController != null) {
        _textEditingController = widget.textController!;
      } else {
        _textEditingController = AttributedTextEditingController();
      }
      _textEditingController.addListener(_sendEditingValueToPlatform);
      _sendEditingValueToPlatform();
    }

    if (widget.minLines != oldWidget.minLines || widget.maxLines != oldWidget.maxLines) {
      // Force a new viewport height calculation.
      _needViewportHeight = true;
    }
  }

  @override
  void dispose() {
    _textEditingController.removeListener(_sendEditingValueToPlatform);
    if (widget.textController == null) {
      _textEditingController.dispose();
    }

    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }

    _scrollController.dispose();

    super.dispose();
  }

  bool get _isMultiline => widget.minLines != 1 || widget.maxLines != 1;

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      if (_textInputConnection == null) {
        print('Attaching TextInputClient to TextInput');
        setState(() {
          _textInputConnection = TextInput.attach(
              this,
              TextInputConfiguration(
                inputAction: widget.textInputAction,
              ));
          _textInputConnection!
            ..show()
            ..setEditingState(currentTextEditingValue!);
        });
      }
    } else {
      print('Detaching TextInputClient from TextInput.');
      setState(() {
        _textInputConnection?.close();
        _textInputConnection = null;
        _textEditingController.selection = const TextSelection.collapsed(offset: -1);
      });
    }
  }

  void _sendEditingValueToPlatform() {
    if (_textInputConnection != null && _textInputConnection!.attached) {
      _textInputConnection!.setEditingState(currentTextEditingValue!);
    }
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  TextEditingValue? get currentTextEditingValue => TextEditingValue(
        text: _textEditingController.text.text,
        selection: _textEditingController.selection,
      );

  @override
  void performAction(TextInputAction action) {
    widget.onPerformActionPressed?.call(action);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // performPrivateCommand() provides a representation for unofficial
    // input commands to be executed. This appears to be an extension point
    // or an escape hatch for input functionality that an app needs to support,
    // but which does not exist at the OS/platform level.
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // This method reports auto-correct bounds when the user selects
    // text with shift+arrow keys on desktop. I'm not sure how to
    // trigger this using only touch interactions. In any event, we're
    // never told when to get rid of the auto-correct range. Therefore,
    // for now, I'm leaving this un-implemented.

    // _textEditingController.text
    //   ..removeAttribution(AutoCorrectAttribution(), TextRange(start: 0, end: _textEditingController.text.text.length))
    //   ..addAttribution(AutoCorrectAttribution(), TextRange(start: start, end: end));
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // TODO: find out why this issue occurs
    //       We ignore platform updates while the floating cursor is moving
    //       because the platform seems to be undoing our floating cursor
    //       changes.
    if (_floatingCursorController.isShowingFloatingCursor) {
      return;
    }

    _textEditingController.text = AttributedText(text: value.text);
    _textEditingController.selection = value.selection;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    _floatingCursorController.updateFloatingCursor(_textKey.currentState!, point);
  }

  @override
  void connectionClosed() {
    print('My TextInputClient: connectionClosed()');
    _textInputConnection = null;
  }

  /// Returns true if the viewport height changed, false otherwise.
  bool _updateViewportHeight() {
    final estimatedLineHeight = _getEstimatedLineHeight();
    final estimatedLinesOfText = _getEstimatedLinesOfText();
    final estimatedContentHeight = estimatedLinesOfText * estimatedLineHeight;
    final minHeight = widget.minLines != null ? widget.minLines! * estimatedLineHeight + widget.padding.vertical : null;
    final maxHeight = widget.maxLines != null ? widget.maxLines! * estimatedLineHeight + widget.padding.vertical : null;
    double? viewportHeight;
    if (maxHeight != null && estimatedContentHeight > maxHeight) {
      viewportHeight = maxHeight;
    } else if (minHeight != null && estimatedContentHeight < minHeight) {
      viewportHeight = minHeight;
    }

    if (!_needViewportHeight && viewportHeight == _viewportHeight) {
      // The height of the viewport hasn't changed. Return.
      return false;
    }

    setState(() {
      _needViewportHeight = false;
      _viewportHeight = viewportHeight;
    });

    return true;
  }

  int _getEstimatedLinesOfText() {
    if (_textEditingController.text.text.isEmpty) {
      return 0;
    }

    if (_textKey.currentState == null) {
      return 0;
    }

    final offsetAtEndOfText =
        _textKey.currentState!.getOffsetAtPosition(TextPosition(offset: _textEditingController.text.text.length));
    int lineCount = (offsetAtEndOfText.dy / _getEstimatedLineHeight()).ceil();

    if (_textEditingController.text.text.endsWith('\n')) {
      lineCount += 1;
    }

    return lineCount;
  }

  double _getEstimatedLineHeight() {
    final defaultStyle = widget.textStyleBuilder({});
    return (defaultStyle.height ?? 1.0) * defaultStyle.fontSize!;
  }

  @override
  Widget build(BuildContext context) {
    if (_textKey.currentContext == null || _needViewportHeight) {
      // The text hasn't been laid out yet, which means our calculations
      // for text height is probably wrong. Schedule a post frame callback
      // to re-calculate the height after initial layout.
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        if (mounted) {
          setState(() {
            _updateViewportHeight();
          });
        }
      });
    }

    return Focus(
      key: _textFieldKey,
      focusNode: _focusNode,
      child: CompositedTransformTarget(
        link: _textFieldLayerLink,
        child: IOSTextfieldInteractor(
          key: _scrollKey,
          focusNode: _focusNode,
          selectableTextKey: _textKey,
          scrollKey: _scrollKey,
          textFieldLayerLink: _textFieldLayerLink,
          textController: _textEditingController,
          editingController: _editingOverlayController,
          scrollController: _scrollController,
          viewportHeight: _viewportHeight,
          isMultiline: _isMultiline,
          handleColor: widget.controlsColor,
          showDebugPaint: widget.showDebugPaint,
          child: ListenableBuilder(
            listenable: _textEditingController,
            builder: (context) {
              final textSpan = _textEditingController.text.text.isNotEmpty
                  ? _textEditingController.text.computeTextSpan(widget.textStyleBuilder)
                  : AttributedText(text: 'enter text').computeTextSpan(
                      (attributions) => widget.textStyleBuilder(attributions).copyWith(color: Colors.grey));

              return Padding(
                padding: widget.padding,
                child: Stack(
                  children: [
                    // TODO: switch out textSelectionDecoration and textCaretFactory
                    //       for backgroundBuilders and foregroundBuilders, respectively
                    //
                    //       add the floating cursor as a foreground builder
                    SuperSelectableText(
                      key: _textKey,
                      textSpan: textSpan,
                      textSelection: _textEditingController.selection,
                      textSelectionDecoration: TextSelectionDecoration(selectionColor: widget.selectionColor),
                      showCaret: true,
                      textCaretFactory: IOSTextFieldCaretFactory(
                        color: _floatingCursorController.isShowingFloatingCursor ? Colors.grey : widget.controlsColor,
                        width: 2,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: IOSFloatingCursor(
                        controller: _floatingCursorController,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
