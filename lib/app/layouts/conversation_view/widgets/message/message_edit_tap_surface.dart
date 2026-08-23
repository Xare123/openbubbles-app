import 'package:flutter/widgets.dart';

/// Makes the complete inline-edit bubble a focus target without disturbing an
/// existing cursor or text selection.
class MessageEditTapSurface extends StatelessWidget {
  const MessageEditTapSurface({
    super.key,
    required this.focusNode,
    required this.child,
  });

  final FocusNode focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (!focusNode.hasFocus && focusNode.canRequestFocus) {
          focusNode.requestFocus();
        }
      },
      child: child,
    );
  }
}
