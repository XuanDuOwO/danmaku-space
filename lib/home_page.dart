import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'anim.dart';
import 'manage_page.dart';
import 'relay_controller.dart';
import 'room_ref.dart';
import 'store.dart';

/// 传送门（模块一）：只负责「怎么进直播间」。
///   - 输入房间号 / 粘贴分享链接
///   - 最近观看过的房间（一键重进）
///   - 我的爱播 / 我的技播名单入口
///
/// 选定房间后由外壳切到「弹幕空间」模块，本身不承载任何弹幕显示。
class PortalTab extends StatefulWidget {
  const PortalTab({
    super.key,
    required this.controller,
    required this.onEnter,
    this.loginName = '',
    this.loginFace = '',
  });

  final RelayController controller;

  /// 选定房间：外壳会连接该房间并切到弹幕空间页。
  final ValueChanged<int> onEnter;

  final String loginName;
  final String loginFace;

  @override
  State<PortalTab> createState() => _PortalTabState();
}

class _PortalTabState extends State<PortalTab> {
  final TextEditingController _ctrl = TextEditingController();
  bool _busy = false;
  String? _err;
  bool _prefilled = false;

  static const _loveColor = Color(0xFFF85149);
  static const _techColor = Color(0xFFE3B341);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCtrl);
    _prefill();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCtrl);
    _ctrl.dispose();
    super.dispose();
  }

  void _onCtrl() {
    if (mounted) setState(() {});
  }

  Future<void> _prefill() async {
    final last = await Store.loadRoomId();
    if (!mounted || _prefilled) return;
    _prefilled = true;
    if (last > 0 && _ctrl.text.isEmpty) _ctrl.text = '$last';
    setState(() {});
  }

  Future<void> _enter() async {
    final raw = _ctrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _err = '请输入直播间号或粘贴分享链接');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    int? room;
    try {
      room = await parseRoomInput(raw);
    } catch (_) {
      room = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (room == null || room <= 0) {
      setState(() => _err = '无法从输入中解析出直播间号');
      return;
    }
    widget.onEnter(room);
  }

  Future<void> _openManage(String type) async {
    await Navigator.of(context).push(
      FadeSlideRoute(ManagePage(initialType: type)),
    );
    await widget.controller.reloadFavs();
  }

  Widget _loginAvatar() {
    final fallback =
        widget.loginName.isNotEmpty ? widget.loginName.substring(0, 1) : '?';
    return Container(
      width: 28,
      height: 28,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF1B2129),
      ),
      child: ClipOval(
        child: widget.loginFace.isNotEmpty
            ? Image.network(
                widget.loginFace,
                width: 28,
                height: 28,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                  child:
                      Text(fallback, style: const TextStyle(fontSize: 12.5)),
                ),
              )
            : Center(
                child:
                    Text(fallback, style: const TextStyle(fontSize: 12.5)),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('传送门', style: TextStyle(fontSize: 16)),
        actions: [
          if (widget.loginName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _loginAvatar(),
                  const SizedBox(width: 8),
                  // 昵称必须完整可见：一行放不下就整体缩小字号（FittedBox），
                  // 绝不出现省略号。
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.45),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        widget.loginName,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: ListView(
        // 四个模块的列表都在同一个 IndexedStack 里，如果不显式指定 primary，
        // 它们会共用同一个 PrimaryScrollController，切换模块时滚动位置会互相串。
        primary: false,
        padding: const EdgeInsets.all(16),
        children: [
          StaggerIn(index: 0, child: _enterCard(cs)),
          const SizedBox(height: 18),
          if (c.recent.isNotEmpty) ...[
            StaggerIn(
              index: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle(cs, '最近观看', action: _clearRecentButton(cs)),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: c.recent
                        .map((r) => _recentChip(cs, r))
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
          StaggerIn(
            index: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle(cs, '我的收藏'),
                _entryTile(
                  icon: Icons.favorite,
                  color: _loveColor,
                  title: '我的爱播',
                  count: c.favsOf('love').length,
                  onTap: () => _openManage('love'),
                ),
                const SizedBox(height: 8),
                _entryTile(
                  icon: Icons.bolt,
                  color: _techColor,
                  title: '我的技播',
                  count: c.favsOf('tech').length,
                  onTap: () => _openManage('tech'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _enterCard(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF11161D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF222831)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('进入直播间',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _enter(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '直播间号，或粘贴分享链接',
              hintStyle: const TextStyle(fontSize: 13.5),
              prefixIcon: const Icon(Icons.link, size: 18),
              suffixIcon: IconButton(
                tooltip: '从剪贴板粘贴',
                icon: const Icon(Icons.content_paste, size: 18),
                onPressed: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  final t = d?.text?.trim() ?? '';
                  if (t.isNotEmpty) setState(() => _ctrl.text = t);
                },
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF2A313C)),
              ),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          if (_err != null) ...[
            const SizedBox(height: 8),
            Text(_err!,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFFF85149))),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _enter,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(_busy ? '解析中…' : '进入弹幕空间'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '支持：房间号 / live.bilibili.com 链接 / b23.tv 分享短链',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
        ],
      ),
    );
  }

  Widget _recentChip(ColorScheme cs, RecentRoom r) {
    return ActionChip(
      avatar: _chipAvatar(r.face, r.name, r.roomId),
      label: Text(
        r.name.isNotEmpty ? r.name : '房间 ${r.roomId}',
        style: const TextStyle(fontSize: 12.5),
      ),
      onPressed: () => widget.onEnter(r.roomId),
    );
  }

  Widget _chipAvatar(String face, String name, int roomId) {
    final fallback = name.isNotEmpty ? name[0] : '$roomId';
    return SizedBox(
      width: 22,
      height: 22,
      child: ClipOval(
        child: face.isNotEmpty
            ? Image.network(
                face,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Center(
                  child: Text(fallback,
                      style: const TextStyle(fontSize: 10.5)),
                ),
              )
            : Center(
                child: Text(fallback,
                    style: const TextStyle(fontSize: 10.5)),
              ),
      ),
    );
  }

  /// 「最近观看」右侧的清除按钮。
  Widget _clearRecentButton(ColorScheme cs) {
    return GestureDetector(
      onTap: _confirmClearRecent,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 13, color: cs.outline),
            const SizedBox(width: 2),
            Text('清除',
                style: TextStyle(fontSize: 11.5, color: cs.outline)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearRecent() async {
    final n = widget.controller.recent.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除最近观看'),
        content: Text('确定清除全部 $n 条最近观看记录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.controller.clearRecent();
  }

  Widget _sectionTitle(ColorScheme cs, String text, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: cs.primary,
              fontWeight: FontWeight.w600,
              letterSpacing: .3,
            ),
          ),
          const Spacer(),
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _entryTile({
    required IconData icon,
    required Color color,
    required String title,
    required int count,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF11161D),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 12),
              Text(title, style: const TextStyle(fontSize: 14.5)),
              const SizedBox(width: 8),
              Text('$count', style: TextStyle(fontSize: 13, color: color)),
              const Spacer(),
              const Icon(Icons.chevron_right,
                  size: 20, color: Color(0xFF6E7681)),
            ],
          ),
        ),
      ),
    );
  }
}
