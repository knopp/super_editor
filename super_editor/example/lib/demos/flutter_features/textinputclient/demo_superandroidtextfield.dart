import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// Demo that displays a very limited Android text field, constructed from
/// the ground up, using [TextInput] for user interaction instead
/// of a [RawKeyboardListener] or similar.
class SuperAndroidTextfieldDemo extends StatefulWidget {
  @override
  _SuperAndroidTextfieldDemoState createState() => _SuperAndroidTextfieldDemoState();
}

class _SuperAndroidTextfieldDemoState extends State<SuperAndroidTextfieldDemo> {
  final _screenFocusNode = FocusNode();
  final _textController = AttributedTextEditingController(
      text: AttributedText(text: 'This is a custom textfield implementation called SuperAndroidTextfield.'));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        print('Removing textfield focus');
        _screenFocusNode.requestFocus();
      },
      behavior: HitTestBehavior.translucent,
      child: Focus(
        focusNode: _screenFocusNode,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: SuperAndroidTextfield(
              textController: _textController,
              selectionColor: Colors.greenAccent.withOpacity(0.4),
              handleColor: Colors.greenAccent,
              inactiveColor: Colors.grey,
            ),
          ),
        ),
      ),
    );
  }
}
