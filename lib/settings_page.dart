import 'package:flutter/material.dart';

import 'anim.dart';
import 'blive/normalize.dart';
import 'relay_controller.dart';
import 'updater.dart';

/// 设置（模块三）：与弹幕空间平级的独立页面，不再是弹幕页里的一个抽屉。
/// 内容：房间信息、弹幕筛选开关、实时数据、账号（退出登录）。
class SettingsTab extends StatefulWidget {
  const SettingsTab({
    super.key,
    required this.controller,
    this.onLogout,
  });

  final RelayController controller;

  /// 退出登录回调（由启动闸门提供）。
  final VoidCallback? onLogout;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  RelayController get _c => widget.controller;

  static const _filterItems = <(EventKind, String, IconData)>[
    (EventKind.danmaku, '弹幕', Icons.chat_bubble_outline),
    (EventKind.gift, '礼物', Icons.card_giftcard),
    (EventKind.guard, '舰长', Icons.directions_boat_outlined),
    (EventKind.superchat, '醒目留言', Icons.attach_money),
    (EventKind.system, '系统', Icons.info_outline),
  ];

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stats = _c.stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontSize: 16)),
      ),
      body: ListView(
        // 见 home_page.dart 的说明：避免与其它模块共用 PrimaryScrollController。
        primary: false,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          StaggerIn(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section(cs, '直播间'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.meeting_room_outlined, size: 20),
            title: const Text('当前房间号', style: TextStyle(fontSize: 14)),
            trailing: Text(
              _c.roomId > 0 ? '${_c.roomId}' : '—',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline, size: 20),
            title: const Text('当前主播', style: TextStyle(fontSize: 14)),
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                (_c.info?.anchorName.isNotEmpty ?? false)
                    ? _c.info!.anchorName
                    : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
              ),
            ),
          ),
          const Divider(height: 1),
          _section(cs, '弹幕筛选（关闭即在弹幕空间列表里隐藏该类消息）'),
          ..._filterItems.map((it) {
            final (kind, label, icon) = it;
            return SwitchListTile(
              dense: true,
              secondary: Icon(icon, size: 20),
              title: Text(label, style: const TextStyle(fontSize: 14)),
              value: !_c.hidden.contains(kind),
              onChanged: (_) => _c.toggleHidden(kind),
            );
          }),
          const Divider(height: 1),
          _section(cs, '实时数据'),
          _statRow(cs, '人气值', stats.popularity),
          _statRow(cs, '粉丝数', stats.fans),
          _statRow(cs, '弹幕数', stats.danmaku),
          _statRow(cs, '礼物数', stats.gift),
          _statRow(cs, '进场数', stats.enter),
          _statRow(cs, '舰长数', stats.guard),
          _statRow(cs, '粉丝团', stats.fansClub),
          const Divider(height: 1),
          _section(cs, '关于'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.system_update_outlined, size: 20),
            title: const Text('检测更新', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _checking
                  ? '正在检查 GitHub / 更新服务器…'
                  : '当前版本 v$kAppVersion',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _checking ? null : _checkUpdate,
          ),
          const Divider(height: 1),
          _section(cs, '账号'),
          ListTile(
            dense: true,
            leading:
                const Icon(Icons.logout, size: 20, color: Color(0xFFF85149)),
            title: const Text('退出登录',
                style: TextStyle(fontSize: 14, color: Color(0xFFF85149))),
            subtitle: const Text('清除本机登录票据并返回扫码页',
                style: TextStyle(fontSize: 11)),
            onTap: _confirmLogout,
          ),
          const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _checking = false;

  /// 检测更新：GitHub 优先，其次自建服务器；发现新版本弹窗让用户选择去更新。
  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    final result = await checkForUpdate();
    if (!mounted) return;
    setState(() => _checking = false);

    final info = result.update;
    if (info != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('发现新版本 v${info.version}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('来源：${info.source} · 当前 v$kAppVersion',
                  style: const TextStyle(fontSize: 12)),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(info.notes,
                    style: const TextStyle(fontSize: 12.5, height: 1.5)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('以后再说'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                openInBrowser(info.url);
              },
              child: const Text('去更新'),
            ),
          ],
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text(result.reached
          ? '已是最新版本 v$kAppVersion'
          : '检测失败：GitHub 与更新服务器都无法连接'),
    ));
  }

  /// 退出登录：先把内存里的弹幕记录落盘，再通知闸门清除登录态。
  void _confirmLogout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后将清除本机保存的登录票据，并返回扫码登录页。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _c.flushLog();
              widget.onLogout?.call();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  Widget _section(ColorScheme cs, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          color: cs.primary,
          fontWeight: FontWeight.w600,
          letterSpacing: .3,
        ),
      ),
    );
  }

  Widget _statRow(ColorScheme cs, String label, int value) {
    return ListTile(
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      trailing: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.4), end: Offset.zero)
                .animate(anim),
            child: child,
          ),
        ),
        child: Text(
          _fmt(value),
          // 数字变化时以内容为 key，触发淡入替换
          key: ValueKey<int>(value),
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  static String _fmt(int v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return '$v';
  }
}
