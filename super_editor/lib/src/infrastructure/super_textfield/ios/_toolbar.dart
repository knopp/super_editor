import 'package:flutter/material.dart';

class IOSTextfieldToolbar extends StatelessWidget {
  const IOSTextfieldToolbar({
    Key? key,
    required this.onCutPressed,
    required this.onCopyPressed,
    required this.onPastePressed,
    required this.onLookUpPressed,
    required this.onSharePressed,
  }) : super(key: key);

  final VoidCallback onCutPressed;
  final VoidCallback onCopyPressed;
  final VoidCallback onPastePressed;
  final VoidCallback onLookUpPressed;
  final VoidCallback onSharePressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      color: const Color(0xFF222222),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildButton(
            onPressed: onCutPressed,
            title: 'Cut',
          ),
          _buildButton(
            onPressed: onCopyPressed,
            title: 'Copy',
          ),
          _buildButton(
            onPressed: onPastePressed,
            title: 'Paste',
          ),
          _buildButton(
            onPressed: onLookUpPressed,
            title: 'Look Up',
          ),
          _buildButton(
            onPressed: onSharePressed,
            title: 'Share...',
          ),
        ],
      ),
    );
  }

  Widget _buildButton({
    required VoidCallback onPressed,
    required String title,
  }) {
    return SizedBox(
      height: 36,
      child: TextButton(
        onPressed: onLookUpPressed,
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: EdgeInsets.zero,
          // padding: const EdgeInsets.symmetric(vertical: 0),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
      ),
    );
  }
}
