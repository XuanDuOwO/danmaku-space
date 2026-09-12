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
///   弹幕记录 —— 跨主播、跨会话的历史弹幕（按日期分类）
///
/// 四个模块之间只通过底部导航互相跳转，谁都不嵌在谁里面；
/// 共享的房间连接、消息流等状态统一放在 [RelayController] 里，
/// 这样切换模块不会断流、也不会丢状态。
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

  int _tab = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _c.boot();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
    // 切到弹幕记录页前先把内存里攒着的弹幕落盘，保证看到的是完整的。
    if (i == 3) unawaited(_c.flushLog());
  }

  /// 传送门选定房间：连上并跳到弹幕空间模块。
  Future<void> _enterRoom(int roomId) async {
    if (mounted) setState(() => _tab = 1);
    await _c.connect(roomId);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          PortalTab(
            controller: _c,
            onEnter: _enterRoom,
            loginName: widget.loginName,
            loginFace: widget.loginFace,
          ),
          DanmakuTab(controller: _c),
          SettingsTab(controller: _c, onLogout: widget.onLogout),
          LogTab(controller: _c, active: _tab == 3),
        ],
      ),
      bottomNavigationBar: NavigationBar(
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
    );
  }
}
