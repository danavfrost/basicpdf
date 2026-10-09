import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Decides when the top bar is visible: hidden while the user scrolls
/// down, shown again after [idle] without scrolling, on scroll-up, or on tap.
class AutoHideController extends ValueNotifier<bool> {
  AutoHideController({this.idle = const Duration(milliseconds: 350)})
    : super(true);

  final Duration idle;
  Timer? _timer;
  bool _pinned = false;

  bool get visible => value;

  /// While pinned (edit mode, dialogs) the bar never hides.
  set pinned(bool p) {
    _pinned = p;
    if (p) show();
  }

  bool get pinned => _pinned;

  /// [delta] > 0 means content moves up (user scrolling down the document).
  void onScroll(double delta) {
    if (_pinned) return;
    if (delta > 0.5) {
      value = false;
    } else if (delta < -0.5) {
      value = true;
    }
    _restartIdle();
  }

  void onScrollEnd() => _restartIdle();

  void show() {
    _timer?.cancel();
    value = true;
  }

  void _restartIdle() {
    _timer?.cancel();
    _timer = Timer(idle, () => value = true);
  }

  /// Feeds scroll notifications from a vertical scrollable.
  bool handleNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0;
      if (d != 0) onScroll(d);
    } else if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.idle) onScrollEnd();
    } else if (n is ScrollEndNotification) {
      onScrollEnd();
    }
    return false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Lays a top bar over [child], sliding it away when [controller] hides it.
class AutoHideScaffold extends StatelessWidget {
  const AutoHideScaffold({
    super.key,
    required this.controller,
    required this.bar,
    required this.child,
  });

  final AutoHideController controller;
  final PreferredSizeWidget bar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: controller.handleNotification,
            child: child,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          // AppBar needs a bounded height (as Scaffold gives it).
          height: MediaQuery.paddingOf(context).top + bar.preferredSize.height,
          child: ValueListenableBuilder<bool>(
            valueListenable: controller,
            builder: (context, visible, bar) => IgnorePointer(
              ignoring: !visible,
              child: AnimatedSlide(
                key: const ValueKey('auto-hide-bar'),
                offset: visible ? Offset.zero : const Offset(0, -1),
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: bar,
              ),
            ),
            child: bar,
          ),
        ),
      ],
    );
  }
}
