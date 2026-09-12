import 'package:flutter/material.dart';

/// 通用轻量动效：
///   [StaggerIn]    —— 内容首次构建时淡入 + 上浮，可按序号错峰；
///   [FadeSlideRoute] —— 页面推入时的淡入 + 轻微上滑过渡。

/// 内容入场动画：淡入 + 从下方 18px 处上浮到原位。
/// [index] 用于错峰：第 0 个立刻开始，后面每个再晚一点，
/// 超过 4 个之后不再增加延迟（避免长列表等太久）。
class StaggerIn extends StatelessWidget {
  const StaggerIn({
    super.key,
    this.index = 0,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final step = index.clamp(0, 4) * 0.15;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 340),
      curve: Interval(step, 1.0, curve: Curves.easeOutCubic),
      builder: (_, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 18),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 页面推入过渡：淡入 + 上滑，比默认 Material 路由更轻快。
class FadeSlideRoute<T> extends PageRouteBuilder<T> {
  FadeSlideRoute(Widget page)
      : super(
          transitionDuration: const Duration(milliseconds: 260),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (_, anim, __, child) {
            final curved =
                CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
            return SlideTransition(
              position: Tween(begin: const Offset(0, 0.05), end: Offset.zero)
                  .animate(curved),
              child: FadeTransition(opacity: curved, child: child),
            );
          },
        );
}
