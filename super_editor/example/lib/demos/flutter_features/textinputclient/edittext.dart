import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class EditTextDemo extends StatefulWidget {
  @override
  _EditTextDemoState createState() => _EditTextDemoState();
}

class _EditTextDemoState extends State<EditTextDemo> {
  final _screenFocusNode = FocusNode();
  final _textController = TextEditingController(
    text:
        'This is a regular EditText, which implements TextInputClient internally. Sed vestibulum ex ac mauris euismod consequat. Sed eu ipsum interdum, feugiat tortor sit amet, suscipit quam. Morbi lacus lectus, gravida ut odio ac, porta rhoncus metus. Curabitur nulla ante, pulvinar a aliquet id, imperdiet placerat justo. Mauris tristique aliquam tincidunt. Quisque eu aliquam risus. Quisque scelerisque ac massa eu aliquet.',
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.purpleAccent),
      ),
      child: GestureDetector(
        onTap: () {
          print('Removing textfield focus');
          _screenFocusNode.requestFocus();
        },
        behavior: HitTestBehavior.translucent,
        child: Focus(
          focusNode: _screenFocusNode,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IntrinsicHeight(
                    child: TextField(
                      controller: _textController,
                      expands: false,
                      minLines: null,
                      maxLines: 5,
                    ),
                  ),
                  // SizedBox(height: 325),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
