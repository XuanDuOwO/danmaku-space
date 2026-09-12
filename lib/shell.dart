import 'dart:async';

import 'package:flutter/material.dart';

import 'danmaku_page.dart';
import 'home_page.dart';
import 'log_page.dart';
import 'relay_controller.dart';
import 'settings_page.dart';

/// 应用外壳：底部导航承载**四个彼此独立、平级**的模块。
///
///   传送门   —— 怎么进直播间（房间号 / 分享链接 / 收藏）
///   弹幕空间 —— 当前房间的实时弹幕
///   设置     —— 筛选、实时数据、账号
///   弹幕记录 —— 按直播间分类的历史弹幕
///
/// 页面之间支持**左右滑动切换**（PageView + KeepAlive，状态不丢）。
/// 弹幕空间进入全屏模式时：隐藏底部导航、禁用滑动，返回键退出全屏。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.loginName = '',
    this.loginFace = '',
    this.onLogout,
  });

  final String loginName;
  final String loginFace;
  final VoidCallback? onLogout;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final RelayController _c = RelayController();
  final PageController _pageCtrl = PageController();

  int _tab = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onCtrl);
    _boot();
  }

  void _onCtrl() {
    // 弹幕空间全屏状态等变化时重建外壳（隐藏/恢复底栏）
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    await _c.boot();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _c.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i == _tab) return;
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    // 切到弹幕记录页前先把内存里攒着的弹幕落盘，保证看到的是完整的。
    if (i == 3) unawaited(_c.flushLog());
  }

  /// 传送门选定房间：连上并跳到弹幕空间模块。
  Future<void> _enterRoom(int roomId) async {
    if (mounted) _go(1);
    await _c.connect(roomId);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final fullscreen = _c.danmakuFullscreen && _tab == 1;
    return PopScope(
      // 弹幕空间全屏时：返回键不退出应用，而是退出全屏
      canPop: !fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _c.danmakuFullscreen) {
          _c.setDanmakuFullscreen(false);
        }
      },
      child: Scaffold(
        // 全屏时隐藏底部导航
        bottomNavigationBar: fullscreen
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: _go,
                height: 62,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.explore_outlined),
                    selectedIcon: Icon(Icons.explore),
                    label: '传送门',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.forum_outlined),
                    selectedIcon: Icon(Icons.forum),
                    label: '弹幕空间',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: '设置',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    selectedIcon: Icon(Icons.receipt_long),
                    label: '弹幕记录',
                  ),
                ],
              ),
        body: PageView(
          controller: _pageCtrl,
          // 全屏模式下禁止滑动切页
          physics: fullscreen ? const NeverScrollableScrollPhysics() : null,
          onPageChanged: (i) {
            setState(() => _tab = i);
            if (i == 3) unawaited(_c.flushLog());
          },
          children: [
            _KeepAlive(
              child: PortalTab(
                controller: _c,
                onEnter: _enterRoom,
                loginName: widget.loginName,
                loginFace: widget.loginFace,
              ),
            ),
            _KeepAlive(child: DanmakuTab(controller: _c)),
            _KeepAlive(
              child: SettingsTab(controller: _c, onLogout: widget.onLogout),
            ),
            _KeepAlive(child: LogTab(controller: _c, active: _tab == 3)),
          ],
        ),
      ),
    );
  }
}

/// 让 PageView 的每一页保持存活（等价于原来 IndexedStack 的不销毁语义）。
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
