import 'package:flutter/material.dart';

import 'pages/danmaku_page.dart';
import 'pages/gift_page.dart';
import 'pages/home_page.dart';
import 'pages/settings_page.dart';
import '../state/relay_controller.dart';
import 'theme.dart';

/// 应用外壳：底部导航承载**三个彼此独立、平级**的模块。
///
///   传送门   —— 怎么进直播间（房间号 / 分享链接 / 收藏）
///   弹幕空间 —— 当前房间的实时弹幕 + 在线人数 + 礼物价值
///   观众礼物 —— 实时观众（在线人数 / 高能榜）与本场礼物价值汇总
///   设置     —— 筛选、实时数据、账号
///
/// 页面之间支持**左右滑动切换**（PageView + KeepAlive，状态不丢）。
/// 弹幕空间进入全屏模式时：隐藏底部导航、禁用滑动，返回键退出全屏。
///
/// 弹幕记录模块已整体移除：按天把每条弹幕写进 SharedPreferences 需要
/// 每 5 秒重写整天 JSON，房间一热闹就是持续的重 IO，收益不成正比。
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

  /// 记住上次的全屏状态，只有它变了才重建外壳。
  /// 早先是「任何 notifyListeners 都 setState」，房间里每秒几十条弹幕
  /// 会把整个外壳连同四个页面一起重建，纯浪费。
  bool _lastFullscreen = false;

  /// 弹幕空间是第几个 tab（全屏逻辑只对它生效）。
  static const int _danmakuTab = 1;

  @override
  void initState() {
    super.initState();
    _lastFullscreen = _c.danmakuFullscreen;
    _c.addListener(_onCtrl);
    _boot();
  }

  void _onCtrl() {
    if (!mounted) return;
    final fs = _c.danmakuFullscreen;
    if (fs != _lastFullscreen) {
      _lastFullscreen = fs;
      setState(() {});
    }
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
  }

  /// 传送门选定房间：连上并跳到弹幕空间模块。
  Future<void> _enterRoom(int roomId) async {
    if (mounted) _go(_danmakuTab);
    await _c.connect(roomId);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final fullscreen = _c.danmakuFullscreen && _tab == _danmakuTab;
    return PopScope(
      // 弹幕空间全屏时：返回键不退出应用，而是退出全屏
      canPop: !fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _c.danmakuFullscreen) {
          _c.setDanmakuFullscreen(false);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
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
                    icon: Icon(Icons.card_giftcard_outlined),
                    selectedIcon: Icon(Icons.card_giftcard),
                    label: '观众礼物',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: '设置',
                  ),
                ],
              ),
        body: PageView(
          controller: _pageCtrl,
          // 全屏模式下禁止滑动切页
          physics: fullscreen ? const NeverScrollableScrollPhysics() : null,
          onPageChanged: (i) {
            setState(() => _tab = i);
            // 离开弹幕空间就关掉亮屏保活，避免用户在别的页面挂机时屏幕不灭。
            if (i != _danmakuTab && _c.keepScreenOn) {
              _c.setKeepScreenOn(false);
            }
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
            _KeepAlive(child: GiftTab(controller: _c)),
            _KeepAlive(
              child: SettingsTab(controller: _c, onLogout: widget.onLogout),
            ),
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
