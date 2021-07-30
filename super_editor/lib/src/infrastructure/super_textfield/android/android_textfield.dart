import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/super_textfield/android/_editing_controls.dart';
import 'package:super_editor/src/infrastructure/super_textfield/android/_user_interaction.dart';
import 'package:super_editor/src/infrastructure/super_textfield/infrastructure/text_scrollview.dart';
import 'package:super_editor/super_editor.dart';

export '_caret.dart';
export '_handles.dart';
export '_toolbar.dart';

final _log = androidTextFieldLog;

class SuperAndroidTextfield extends StatefulWidget {
  const SuperAndroidTextfield({
    Key? key,
    this.focusNode,
    this.textController,
    required this.caretColor,
    required this.selectionColor,
    required this.handlesColor,
    this.textStyleBuilder = defaultStyleBuilder,
    this.minLines,
    this.maxLines = 1,
    this.lineHeight,
    this.textInputAction = TextInputAction.done,
    this.showDebugPaint = false,
    this.onPerformActionPressed,
  })  : assert(minLines == null || minLines == 1 || lineHeight != null, 'minLines > 1 requires a non-null lineHeight'),
        assert(maxLines == null || maxLines == 1 || lineHeight != null, 'maxLines > 1 requires a non-null lineHeight'),
        super(key: key);

  /// [FocusNode] attached to this text field.
  final FocusNode? focusNode;

  /// Controller that owns the text content and text selection for
  /// this text field.
  final AttributedTextEditingController? textController;

  /// Text style factory that creates styles for the content in
  /// [textController] based on the attributions in that content.
  final AttributionStyleBuilder textStyleBuilder;

  /// Color of the caret.
  final Color caretColor;

  /// Color of the selection rectangle for selected text.
  final Color selectionColor;

  /// Color of the selection handles.
  final Color handlesColor;

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

  /// The type of action associated with the action button on the mobile
  /// keyboard.
  final TextInputAction textInputAction;

  /// Whether to paint debug guides.
  final bool showDebugPaint;

  /// Callback invoked when the user presses the "action" button
  /// on the keyboard, e.g., "done", "call", "emergency", etc.
  final Function(TextInputAction)? onPerformActionPressed;

  @override
  _SuperAndroidTextfieldState createState() => _SuperAndroidTextfieldState();
}

class _SuperAndroidTextfieldState extends State<SuperAndroidTextfield>
    with SingleTickerProviderStateMixin
    implements TextInputClient {
  final _textFieldKey = GlobalKey();
  final _textFieldLayerLink = LayerLink();
  final _textContentLayerLink = LayerLink();
  final _scrollKey = GlobalKey<IOSTextFieldTouchInteractorState>();
  final _textContentKey = GlobalKey<SuperSelectableTextState>();

  late FocusNode _focusNode;

  late AttributedTextEditingController _textEditingController;
  TextInputConnection? _textInputConnection;

  final _magnifierLayerLink = LayerLink();
  late AndroidEditingOverlayController _editingOverlayController;

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
      _showEditingControlsOverlay();
    }

    _textEditingController = (widget.textController ?? AttributedTextEditingController())
      ..addListener(_sendEditingValueToPlatform);

    _textScrollController = TextScrollController(
      textController: _textEditingController,
      tickerProvider: this,
    )..addListener(_onTextScrollChange);

    _editingOverlayController = AndroidEditingOverlayController(
      textController: _textEditingController,
      magnifierFocalPoint: _magnifierLayerLink,
    );
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
        _rebuildEditingOverlayControls();
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
    _removeEditingOverlayControls();

    WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
      _showEditingControlsOverlay();
    });
  }

  @override
  void dispose() {
    _removeEditingOverlayControls();

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
        _log.info('Attaching TextInputClient to TextInput');
        setState(() {
          _textInputConnection = TextInput.attach(
              this,
              TextInputConfiguration(
                inputAction: widget.textInputAction,
              ));
          _textInputConnection!
            ..show()
            ..setEditingState(currentTextEditingValue!);

          _showEditingControlsOverlay();
        });
      }
    } else {
      _log.info('Detaching TextInputClient from TextInput.');
      setState(() {
        _textInputConnection?.close();
        _textInputConnection = null;
        _textEditingController.selection = const TextSelection.collapsed(offset: -1);
        _removeEditingOverlayControls();
      });
    }
  }

  void _onTextScrollChange() {
    if (_controlsOverlayEntry != null) {
      _rebuildEditingOverlayControls();
    }
  }

  /// Displays [IOSEditingControls] in the app's [Overlay], if not already
  /// displayed.
  void _showEditingControlsOverlay() {
    if (_controlsOverlayEntry == null) {
      _controlsOverlayEntry = OverlayEntry(builder: (overlayContext) {
        return AndroidEditingOverlayControls(
          editingController: _editingOverlayController,
          textScrollController: _textScrollController,
          textFieldLayerLink: _textFieldLayerLink,
          textFieldKey: _textFieldKey,
          textContentLayerLink: _textContentLayerLink,
          textContentKey: _textContentKey,
          handleColor: widget.handlesColor,
          showDebugPaint: widget.showDebugPaint,
        );
      });

      Overlay.of(context)!.insert(_controlsOverlayEntry!);
    }
  }

  /// Rebuilds the [IOSEditingControls] in the app's [Overlay], if
  /// they're currently displayed.
  void _rebuildEditingOverlayControls() {
    _controlsOverlayEntry?.markNeedsBuild();
  }

  /// Removes [IOSEditingControls] from the app's [Overlay], if they're
  /// currently displayed.
  void _removeEditingOverlayControls() {
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
    _textEditingController.text = AttributedText(text: value.text);
    _textEditingController.selection = value.selection;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // No floating cursor on Android.
  }

  @override
  void connectionClosed() {
    _log.info('TextInputClient: connectionClosed()');
    _textInputConnection = null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      key: _textFieldKey,
      focusNode: _focusNode,
      child: CompositedTransformTarget(
        link: _textFieldLayerLink,
        child: AndroidTextFieldTouchInteractor(
          focusNode: _focusNode,
          selectableTextKey: _textContentKey,
          textFieldLayerLink: _textFieldLayerLink,
          textController: _textEditingController,
          editingOverlayController: _editingOverlayController,
          textScrollController: _textScrollController,
          isMultiline: _isMultiline,
          handleColor: widget.handlesColor,
          showDebugPaint: widget.showDebugPaint,
          child: TextScrollView(
            key: _scrollKey,
            textScrollController: _textScrollController,
            textKey: _textContentKey,
            textEditingController: _textEditingController,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            lineHeight: widget.lineHeight,
            perLineAutoScrollDuration: const Duration(milliseconds: 100),
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
                          color: widget.caretColor,
                          width: 2,
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
    );
  }
}
