import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// Demo of [SuperIOSTextfield].
class SuperIOSTextfieldDemo extends StatefulWidget {
  @override
  _SuperIOSTextfieldDemoState createState() => _SuperIOSTextfieldDemoState();
}

class _SuperIOSTextfieldDemoState extends State<SuperIOSTextfieldDemo> {
  final _screenFocusNode = FocusNode();
  final _textController = AttributedTextEditingController(
      text: AttributedText(
          text:
              'This is a custom textfield implementation called SuperIOSTextfield. It is super long so that we can mess with scrolling. This drags it out even further so that we can get multiline scrolling, too. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Proin tempor sapien est, in eleifend purus rhoncus fringilla. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Nulla varius libero lorem, eget tincidunt ante porta accumsan. Morbi quis ante at nunc molestie ullamcorper.'));

  bool _showDebugPaint = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onTap: () {
          print('Removing textfield focus');
          _screenFocusNode.requestFocus();
        },
        behavior: HitTestBehavior.translucent,
        child: Focus(
          focusNode: _screenFocusNode,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SuperIOSTextfield(
                        textController: _textController,
                        textStyleBuilder: _styleBuilder,
                        selectionColor: Colors.blue.withOpacity(0.4),
                        controlsColor: Colors.blue,
                        minLines: 1,
                        maxLines: 1,
                        showDebugPaint: _showDebugPaint,
                      ),
                      const SizedBox(height: 48),
                      SuperIOSTextfield(
                        textController: _textController,
                        textStyleBuilder: _styleBuilder,
                        selectionColor: Colors.blue.withOpacity(0.4),
                        controlsColor: Colors.blue,
                        maxLines: 4,
                        showDebugPaint: _showDebugPaint,
                      ),
                      const SizedBox(height: 48),
                      SuperIOSTextfield(
                        textController: _textController,
                        textStyleBuilder: _styleBuilder,
                        selectionColor: Colors.blue.withOpacity(0.4),
                        controlsColor: Colors.blue,
                        maxLines: null,
                        showDebugPaint: _showDebugPaint,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _showDebugPaint = !_showDebugPaint;
          });
        },
        child: Icon(Icons.bug_report),
      ),
    );
  }

  TextStyle _styleBuilder(Set<Attribution> attributions) {
    return const TextStyle(
      color: Colors.black,
      fontSize: 22,
      height: 1.4,
    );
  }
}
