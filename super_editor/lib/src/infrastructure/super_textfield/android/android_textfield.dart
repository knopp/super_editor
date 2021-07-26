import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';
import 'package:super_editor/super_editor.dart';

import 'editing_controls.dart';

export 'caret.dart';
export 'editing_controls.dart';
export 'handles.dart';
export 'toolbar.dart';

class SuperAndroidTextfield extends StatefulWidget {
  const SuperAndroidTextfield({
    Key? key,
    this.focusNode,
    this.textController,
    required this.selectionColor,
    required this.handleColor,
    required this.inactiveColor,
  }) : super(key: key);

  final FocusNode? focusNode;
  final AttributedTextEditingController? textController;
  final Color selectionColor;
  final Color handleColor;
  final Color inactiveColor;

  @override
  _SuperAndroidTextfieldState createState() => _SuperAndroidTextfieldState();
}

class _SuperAndroidTextfieldState extends State<SuperAndroidTextfield> implements TextInputClient {
  final _textKey = GlobalKey<SuperSelectableTextState>();

  late FocusNode _focusNode;

  late AttributedTextEditingController _textEditingController;
  TextInputConnection? _textInputConnection;

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
  void didUpdateWidget(SuperAndroidTextfield oldWidget) {
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
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: _focusNode.hasFocus ? widget.selectionColor : widget.inactiveColor,
            ),
          ),
        ),
        child: ListenableBuilder(
          listenable: _textEditingController,
          builder: (context) {
            return SuperSelectableText.plain(
              key: _textKey,
              text: _textEditingController.text.text.isNotEmpty ? _textEditingController.text.text : 'enter text',
              textSelection: _textEditingController.selection,
              textSelectionDecoration: TextSelectionDecoration(selectionColor: widget.selectionColor),
              showCaret: true,
              textCaretFactory: _AndroidTextControlsFactory(
                focusNode: _focusNode,
                text: _textEditingController.text,
                color: widget.handleColor,
                width: 2,
                onDragSelectionChanged: (newSelection) {
                  print('Updating selection to $newSelection, input connection: $_textInputConnection');
                  _textEditingController.selection = newSelection;
                  _sendEditingValueToPlatform();
                },
              ),
              style: TextStyle(
                color: _textEditingController.text.text.isNotEmpty ? Colors.black : Colors.grey,
                fontSize: 18,
                height: 1.4,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AndroidTextControlsFactory implements TextCaretFactory {
  _AndroidTextControlsFactory({
    required FocusNode focusNode,
    required AttributedText text,
    required Color color,
    double width = 1.0,
    BorderRadius borderRadius = BorderRadius.zero,
    required void Function(TextSelection newSelection) onDragSelectionChanged,
  })  : _focusNode = focusNode,
        _text = text,
        _color = color,
        _width = width,
        _borderRadius = borderRadius,
        _onDragSelectionChanged = onDragSelectionChanged;

  final FocusNode _focusNode;
  final AttributedText _text;
  final void Function(TextSelection newSelection) _onDragSelectionChanged;
  final Color _color;
  final double _width;
  final BorderRadius _borderRadius;

  @override
  Widget build({
    required BuildContext context,
    required TextLayout textLayout,
    required TextSelection selection,
    required bool isTextEmpty,
    required bool showCaret,
  }) {
    return AndroidTextfieldControls(
      focusNode: _focusNode,
      textLayout: textLayout,
      // TODO: get rid of this type cast and the use of SuperSelectableTextState
      selectableText: textLayout as SuperSelectableTextState,
      text: _text,
      selection: selection,
      color: _color,
      width: _width,
      borderRadius: _borderRadius,
      showCaret: showCaret,
      onDragSelectionChanged: _onDragSelectionChanged,
    );
  }
}
