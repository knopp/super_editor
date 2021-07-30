import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/default_editor/super_editor.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';
import 'package:super_editor/src/infrastructure/super_textfield/ios/_editing_controls.dart';
import 'package:super_editor/src/infrastructure/super_textfield/ios/_text_scrollview.dart';

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
    this.lineHeight,
    this.padding = EdgeInsets.zero,
    this.textInputAction = TextInputAction.done,
    this.showDebugPaint = false,
    this.onPerformActionPressed,
  })  : assert(minLines == null || minLines == 1 || lineHeight != null, 'minLines > 1 requires a non-null lineHeight'),
        assert(maxLines == null || maxLines == 1 || lineHeight != null, 'maxLines > 1 requires a non-null lineHeight'),
        super(key: key);

  final FocusNode? focusNode;

  final AttributedTextEditingController? textController;

  final AttributionStyleBuilder textStyleBuilder;

  final Color selectionColor;

  final Color controlsColor;

  /// The minimum height of this text field, represented as a
  /// line count.
  ///
  /// If [minLines] is non-null and greater than `1`, [lineHeight]
  /// must also be provided because there is no guarantee that all
  /// lines of text have the same height.
  ///
  /// See also:
  ///
  ///  * [maxLines]
  ///  * [lineHeight]
  final int? minLines;

  /// The maximum height of this text field, represented as a
  /// line count.
  ///
  /// If text exceeds the maximum line height, scrolling dynamics
  /// are added to accommodate the overflowing text.
  ///
  /// If [maxLines] is non-null and greater than `1`, [lineHeight]
  /// must also be provided because there is no guarantee that all
  /// lines of text have the same height.
  ///
  /// See also:
  ///
  ///  * [minLines]
  ///  * [lineHeight]
  final int? maxLines;

  /// The height of a single line of text in this text field, used
  /// with [minLines] and [maxLines] to size the text field.
  ///
  /// An explicit [lineHeight] is required because rich text in this
  /// text field might have lines of varying height, which would
  /// result in a constantly changing text field height during scrolling.
  /// To avoid that situation, a single, explicit [lineHeight] is
  /// provided and used for all text field height calculations.
  final double? lineHeight;

  final EdgeInsets padding;

  final TextInputAction textInputAction;

  final bool showDebugPaint;

  /// Callback invoked when the user presses the "action" button
  /// on the keyboard, e.g., "done", "call", "emergency", etc.
  final Function(TextInputAction)? onPerformActionPressed;

  @override
  _SuperIOSTextfieldState createState() => _SuperIOSTextfieldState();
}

class _SuperIOSTextfieldState extends State<SuperIOSTextfield>
    with SingleTickerProviderStateMixin
    implements TextInputClient {
  final _textFieldKey = GlobalKey();
  final _textFieldLayerLink = LayerLink();
  final _textContentLayerLink = LayerLink();
  final _scrollKey = GlobalKey<IOSTextFieldTouchInteractorState>();
  final _textContentKey = GlobalKey<SuperSelectableTextState>();

  late FocusNode _focusNode;

  late AttributedTextEditingController _textEditingController;
  late FloatingCursorController _floatingCursorController;
  TextInputConnection? _textInputConnection;

  final _magnifierLayerLink = LayerLink();
  late IOSEditingOverlayController _editingOverlayController;

  late TextScrollController _textScrollController;

  // OverlayEntry that displays the toolbar and magnifier, and
  // positions the invisible touch targets for base/extent
  // dragging.
  OverlayEntry? _controlsOverlayEntry;

  @override
  void initState() {
    super.initState();
    _focusNode = (widget.focusNode ?? FocusNode())
      ..unfocus()
      ..addListener(_onFocusChange);
    if (_focusNode.hasFocus) {
      _showHandles();
    }

    _textEditingController = (widget.textController ?? AttributedTextEditingController())
      ..addListener(_sendEditingValueToPlatform);

    _textScrollController = TextScrollController(
      textController: _textEditingController,
      tickerProvider: this,
    )..addListener(_onTextScrollChange);

    _floatingCursorController = FloatingCursorController(
      textController: _textEditingController,
    );

    _editingOverlayController = IOSEditingOverlayController(
      textController: _textEditingController,
      magnifierFocalPoint: _magnifierLayerLink,
    );

    // _testAutoScrolling();
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
    _removeHandles();

    WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
      _showHandles();
    });
  }

  @override
  void dispose() {
    _removeHandles();

    _textEditingController.removeListener(_sendEditingValueToPlatform);
    if (widget.textController == null) {
      _textEditingController.dispose();
    }

    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }

    _textScrollController
      ..removeListener(_onTextScrollChange)
      ..dispose();

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

          _showHandles();
        });
      }
    } else {
      print('Detaching TextInputClient from TextInput.');
      setState(() {
        _textInputConnection?.close();
        _textInputConnection = null;
        _textEditingController.selection = const TextSelection.collapsed(offset: -1);
        _removeHandles();
      });
    }
  }

  void _onTextScrollChange() {
    if (_controlsOverlayEntry != null) {
      _rebuildHandles();
    }
  }

  /// Displays [IOSEditingControls] in the app's [Overlay], if not already
  /// displayed.
  void _showHandles() {
    if (_controlsOverlayEntry == null) {
      _controlsOverlayEntry = OverlayEntry(builder: (overlayContext) {
        return IOSEditingControls(
          editingController: _editingOverlayController,
          textScrollController: _textScrollController,
          textFieldLayerLink: _textFieldLayerLink,
          textFieldKey: _textFieldKey,
          textContentLayerLink: _textContentLayerLink,
          textContentKey: _textContentKey,
          handleColor: widget.controlsColor,
          showDebugPaint: widget.showDebugPaint,
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
    _floatingCursorController.updateFloatingCursor(_textContentKey.currentState!, point);
  }

  @override
  void connectionClosed() {
    print('My TextInputClient: connectionClosed()');
    _textInputConnection = null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      key: _textFieldKey,
      focusNode: _focusNode,
      child: CompositedTransformTarget(
        link: _textFieldLayerLink,
        child: IOSTextFieldTouchInteractor(
          focusNode: _focusNode,
          selectableTextKey: _textContentKey,
          textFieldLayerLink: _textFieldLayerLink,
          textController: _textEditingController,
          editingOverlayController: _editingOverlayController,
          textScrollController: _textScrollController,
          isMultiline: _isMultiline,
          handleColor: widget.controlsColor,
          showDebugPaint: widget.showDebugPaint,
          child: Padding(
            padding: widget.padding,
            child: TextScrollView(
              key: _scrollKey,
              textScrollController: _textScrollController,
              textKey: _textContentKey,
              textEditingController: _textEditingController,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              lineHeight: widget.lineHeight,
              showDebugPaint: widget.showDebugPaint,
              child: ListenableBuilder(
                listenable: _textEditingController,
                builder: (context) {
                  final textSpan = _textEditingController.text.text.isNotEmpty
                      ? _textEditingController.text.computeTextSpan(widget.textStyleBuilder)
                      : AttributedText(text: 'enter text').computeTextSpan(
                          (attributions) => widget.textStyleBuilder(attributions).copyWith(color: Colors.grey));

                  return CompositedTransformTarget(
                    link: _textContentLayerLink,
                    child: Stack(
                      children: [
                        // TODO: switch out textSelectionDecoration and textCaretFactory
                        //       for backgroundBuilders and foregroundBuilders, respectively
                        //
                        //       add the floating cursor as a foreground builder
                        SuperSelectableText(
                          key: _textContentKey,
                          textSpan: textSpan,
                          textSelection: _textEditingController.selection,
                          textSelectionDecoration: TextSelectionDecoration(selectionColor: widget.selectionColor),
                          showCaret: true,
                          textCaretFactory: IOSTextFieldCaretFactory(
                            color:
                                _floatingCursorController.isShowingFloatingCursor ? Colors.grey : widget.controlsColor,
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
        ),
      ),
    );
  }
}
