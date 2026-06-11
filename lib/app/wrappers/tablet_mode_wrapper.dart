import 'dart:math';

import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:defer_pointer/defer_pointer.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class TabletModeWrapper extends StatefulWidget {
  final Widget left;
  final Widget right;
  final double initialRatio;
  final double dividerWidth;
  final double minRatio;
  final double maxRatio;
  final bool allowResize;
  final double? minWidthLeft;
  final double? maxWidthLeft;
  final double dragMargin;

  const TabletModeWrapper(
      {super.key,
      required this.left,
      required this.right,
      this.initialRatio = 0.5,
      this.allowResize = true,
      this.dividerWidth = 3.0,
      this.minRatio = 0,
      this.maxRatio = 0,
      this.minWidthLeft,
      this.maxWidthLeft,
      this.dragMargin = 5})
      : assert(initialRatio >= 0),
        assert(initialRatio <= 1);

  @override
  State<TabletModeWrapper> createState() => _TabletModeWrapperState();
}

class _TabletModeWrapperState extends State<TabletModeWrapper> with ThemeHelpers {
  //from 0-1
  late final RxDouble _ratio;
  double? _maxWidth;
  bool? altLayoutCache;

  get _width1 => max(
      min(_ratio * _maxWidth!, widget.maxWidthLeft ?? double.infinity), widget.minWidthLeft ?? double.negativeInfinity);

  get _width2 => _maxWidth! - _width1;

  @override
  void initState() {
    super.initState();
    _ratio =
        RxDouble((PrefsSvc.i.getDouble('splitRatio') ?? widget.initialRatio).clamp(widget.minRatio, widget.maxRatio));
    EventDispatcherSvc.stream.listen((event) {
      if (event.type == 'split-refresh') {
        _ratio.value = PrefsSvc.i.getDouble('splitRatio') ?? _ratio.value;
        setState(() {});
      } else if (event.type == 'override-split') {
        _ratio.value = event.data;
        setState(() {});
      }
    });
    debounce<double>(_ratio, (val) async {
      await PrefsSvc.i.setDouble('splitRatio', val);
      EventDispatcherSvc.emit('split-refresh', null);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!showAltLayout) {
      // this forcefully closes the chat controller if rotating from landscape -> portrait
      if ((altLayoutCache ?? false) && ChatsSvc.activeChat != null) {
        altLayoutCache = false;
        cvc(ChatsSvc.activeChat!.chat).close();
      }
      return TitleBarWrapper(child: widget.left);
    }
    altLayoutCache = true;
    return LayoutBuilder(
      builder: (context, BoxConstraints constraints) {
        _maxWidth = constraints.maxWidth - widget.dividerWidth;
        return DeferredPointerHandler(
          child: TitleBarWrapper(
            child: SizedBox(
              width: constraints.maxWidth,
              child: Obx(() => Row(
                    children: <Widget>[
                      SizedBox(
                        width: _width1,
                        child: widget.left,
                      ),
                      (widget.allowResize)
                          ? SizedBox(
                              width: widget.dividerWidth,
                              height: constraints.maxHeight,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned(
                                    top: 0,
                                    left: -widget.dragMargin,
                                    right: -widget.dragMargin,
                                    bottom: 0,
                                    child: DeferPointer(
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.resizeLeftRight,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          child: Center(
                                            child: Container(
                                              color: context.theme.colorScheme.surfaceContainerHighest,
                                              width: widget.dividerWidth,
                                            ),
                                          ),
                                          onPanUpdate: (DragUpdateDetails details) {
                                            _ratio.value = (_ratio.value + (details.delta.dx / _maxWidth!))
                                                .clamp(widget.minRatio, widget.maxRatio);
                                            NavigationSvc.listener.refresh();
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Container(
                              width: widget.dividerWidth,
                              height: constraints.maxHeight,
                              color: context.theme.colorScheme.surfaceContainerHighest),
                      SizedBox(
                        width: _width2,
                        child: widget.right,
                      ),
                    ],
                  )),
            ),
          ),
        );
      },
    );
  }
}
