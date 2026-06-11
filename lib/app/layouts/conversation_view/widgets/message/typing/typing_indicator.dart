import 'dart:math' as math;

import 'package:bluebubbles/app/components/avatars/contact_avatar_group_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/typing/typing_clipper.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({
    super.key,
    this.visible,
    this.controller,
    this.scale = 1.0,
  });

  final bool? visible;
  final ConversationViewController? controller;
  final double scale;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> with ThemeHelpers {
  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: (widget.controller?.showTypingIndicatorFor.isNotEmpty ?? widget.visible)!
          ? (iOS || ChatStateScope.maybeChatOf(context) == null
              ? ClipPath(
                  clipper: const TypingClipper(),
                  child: Container(
                    height: 50,
                    color: context.theme.colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.fromLTRB(30, 10, 14, 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.controller != null &&
                            widget.controller!.showTypingIndicatorFor.length == 1 &&
                            widget.controller!
                                    .typingIndicatorData[widget.controller!.showTypingIndicatorFor.first.address]?.$2 !=
                                null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(99),
                              child: Image.memory(
                                widget.controller!
                                    .typingIndicatorData[widget.controller!.showTypingIndicatorFor.first.address]!.$2!,
                              ),
                            ),
                          ),
                        const AnimatedDot(index: 2),
                        const AnimatedDot(index: 1),
                        const AnimatedDot(index: 0),
                      ],
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 10, right: 10),
                      child: ContactAvatarGroupWidget(
                        participants: [...(widget.controller?.showTypingIndicatorFor ?? [])],
                        size: 25,
                        editable: false,
                      ),
                    ),
                    if (widget.controller != null &&
                        widget.controller!.showTypingIndicatorFor.length == 1 &&
                        widget.controller!.typingIndicatorData[widget.controller!.showTypingIndicatorFor.first.address]
                                ?.$2 !=
                            null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        height: 25,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: Image.memory(
                            widget.controller!
                                .typingIndicatorData[widget.controller!.showTypingIndicatorFor.first.address]!.$2!,
                          ),
                        ),
                      ),
                    const AnimatedDot(index: 2),
                    const AnimatedDot(index: 1),
                    const AnimatedDot(index: 0),
                  ],
                ))
          : const SizedBox.shrink(),
    );
  }
}

class AnimatedDot extends StatefulWidget {
  final int index;
  const AnimatedDot({super.key, required this.index});

  @override
  State<AnimatedDot> createState() => _AnimatedDotState();
}

class _AnimatedDotState extends State<AnimatedDot> with SingleTickerProviderStateMixin, ThemeHelpers {
  late final AnimationController _controller;
  late final Animation animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700), animationBehavior: AnimationBehavior.preserve);
    _controller.addStatusListener((state) {
      if (state == AnimationStatus.completed && mounted) {
        _controller.forward(from: 0.0);
      }
    });

    animation = Tween(
      begin: 0.0,
      end: math.pi,
    ).animate(_controller);

    _controller.forward(from: 0.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (iOS) {
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final amt = (math.sin(animation.value + (widget.index) * math.pi / 4).abs() * 20).clamp(1, 20).toDouble();
          return Container(
            decoration: BoxDecoration(
              color: ThemeSvc.inDarkMode(context)
                  ? context.theme.colorScheme.surfaceContainerHighest.lightenPercent(amt)
                  : context.theme.colorScheme.surfaceContainerHighest.darkenPercent(amt),
              shape: BoxShape.circle,
            ),
            width: 10,
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 2),
          );
        },
      );
    } else {
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          return Padding(
            padding: EdgeInsets.only(
                bottom: (math.sin(animation.value + (widget.index) * math.pi / 4).abs() * 20).clamp(1, 20).toDouble()),
            child: Container(
              decoration: BoxDecoration(
                color: context.theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              width: 4,
              height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 2),
            ),
          );
        },
      );
    }
  }
}
