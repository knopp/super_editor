import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/default_editor/super_editor.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';

import '../../attributed_text.dart';
import '../../super_selectable_text.dart';
import '../super_textfield.dart' hide SuperTextFieldScrollview, SuperTextFieldScrollviewState;
import '_caret.dart';
import '_editing_controls.dart';

export '_caret.dart';
export '_editing_controls.dart';
export '_handles.dart';
export '_magnifier.dart';
export '_toolbar.dart';

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
    this.showDebugPaint = false,
  }) : super(key: key);

  final FocusNode? focusNode;

  final AttributedTextEditingController? textController;

  final AttributionStyleBuilder textStyleBuilder;

  final Color selectionColor;

  final Color controlsColor;

  final int? minLines;
  final int? maxLines;

  final EdgeInsets padding;

  final bool showDebugPaint;

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
  TextInputConnection? _textInputConnection;

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
    print('Textfield focus change - has focus: ${_focusNode.hasFocus}');
    if (_focusNode.hasFocus) {
      if (_textInputConnection == null) {
        print('Attaching TextInputClient to TextInput');
        setState(() {
          _textInputConnection = TextInput.attach(this, const TextInputConfiguration());
          _textInputConnection!
            ..show()
            ..setEditingState(currentTextEditingValue!);
        });
      }
    } else {
      print('Detaching TextInputClient from TextInput');
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
    // performAction() is called when the "done" button is pressed in
    // various "text configurations". For example, sometimes the "done"
    // button says "Call" or "Next", depending on the current text input
    // configuration. We don't need to worry about this for a barebones
    // implementation.
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
    // I'm not sure why iOS wants to show an "autocorrection" rectangle
    // when we already have a selection visible.
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    _textEditingController.text = AttributedText(text: value.text);
    _textEditingController.selection = value.selection;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // no-op: this is an iOS-only behavior
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
          scrollController: _scrollController,
          viewportHeight: _viewportHeight,
          isMultiline: _isMultiline,
          handleColor: widget.controlsColor,
          showDebugPaint: widget.showDebugPaint,
          child: ListenableBuilder(
            listenable: _textEditingController,
            builder: (context) {
              return Padding(
                padding: widget.padding,
                child: SuperSelectableText.plain(
                  key: _textKey,
                  text: _textEditingController.text.text.isNotEmpty ? _textEditingController.text.text : 'enter text',
                  textSelection: _textEditingController.selection,
                  textSelectionDecoration: TextSelectionDecoration(selectionColor: widget.selectionColor),
                  showCaret: true,
                  textCaretFactory: IOSTextFieldCaretFactory(
                    color: widget.controlsColor,
                    width: 2,
                  ),
                  style: widget.textStyleBuilder({}),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
