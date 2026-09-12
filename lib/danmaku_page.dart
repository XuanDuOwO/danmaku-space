import 'package:flutter/material.dart';

import 'anim.dart';
import 'blive/client.dart';
import 'blive/normalize.dart';
import 'emoji_text.dart';
import 'manage_page.dart';
import 'relay_controller.dart';

/// 弹幕空间（模块二）：当前房间的实时弹幕。
/// 只承载「直播间信息 + 收藏图标 + 进场提示 + 弹幕列表」，
/// 设置与弹幕记录都是平级的独立模块，不从这里进入。
class DanmakuTab extends StatefulWidget {
  const DanmakuTab({super.key, required this.controller});

  final RelayController controller;

  @override
  State<DanmakuTab> createState() => _DanmakuTabState();
}

class _DanmakuTabState extends State<DanmakuTab> {
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;

  RelayController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final n = _c.messages.length;
    if (n != _lastCount) {
      _lastCount = n;
      _autoScroll();
    }
    setState(() {});
  }

  void _autoScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max - _scroll.position.pixels < 120) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  Future<void> _openManage(String type) async {
    final picked = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => ManagePage(initialType: type)),
    );
    await _c.reloadFavs();
    if (!mounted) return;
    if (picked != null && picked > 0 && picked != _c.roomId) {
      await _c.connect(picked);
    }
  }

  Future<void> _toggleFav(String type) async {
    final msg = await _c.toggleFavoriteOf(type);
    _snack(msg);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fs = _c.danmakuFullscreen;
    // 全屏时挖孔摄像头会遮挡内容：竖屏整体下移 2 个标题高度（左右不变），
    // 横屏弹幕起始位置右移 1 个标题宽度（上下不变）；取系统实际挖孔避让与
    // 固定偏移的较大值，两种挖孔位置都能盖住。
    EdgeInsets fsPad = EdgeInsets.zero;
    if (fs) {
      const unit = 48.0; // 一个「大标题」高度/宽度基准
      final mq = MediaQuery.of(context);
      final landscape = mq.orientation == Orientation.landscape;
      fsPad = landscape
          ? EdgeInsets.only(left: mq.viewPadding.left > unit ? mq.viewPadding.left : unit)
          : EdgeInsets.only(top: mq.viewPadding.top > unit * 2 ? mq.viewPadding.top : unit * 2);
    }
    return Scaffold(
      // 全屏模式：隐藏「弹幕空间」标题栏，只留直播间信息条和弹幕列表
      appBar: fs
          ? null
          : AppBar(
              title: const Text('弹幕空间', style: TextStyle(fontSize: 16)),
              actions: [
                IconButton(
                  tooltip: '重新连接',
                  icon: const Icon(Icons.refresh),
                  onPressed: _c.roomId > 0 ? _c.refresh : null,
                ),
                IconButton(
                  tooltip: '全屏弹幕',
                  icon: const Icon(Icons.fullscreen),
                  onPressed: _c.roomId > 0
                      ? () => _c.setDanmakuFullscreen(true)
                      : null,
                ),
              ],
            ),
      body: Padding(
        padding: fsPad,
        child: Column(
          children: [
            _buildTopBar(cs),
            _buildEnterTicker(cs),
            const Divider(height: 1),
            Expanded(child: _buildList(cs)),
          ],
        ),
      ),
    );
  }

  /// 始终可见的直播间信息条（含主播头像）+ 爱播/技播图标。
  Widget _buildTopBar(ColorScheme cs) {
    final (String stateText, Color stateColor) = switch (_c.state) {
      ConnState.connecting || ConnState.reconnecting =>
        ('连接中…', const Color(0xFFD29922)),
      ConnState.connected => ('已连接', const Color(0xFF3FB950)),
      ConnState.error => ('异常', const Color(0xFFF85149)),
      ConnState.idle => ('未连接', const Color(0xFF6E7681)),
    };
    final info = _c.info;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF11161D),
        border: Border(bottom: BorderSide(color: Color(0xFF222831))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _anchorAvatar(cs),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (info != null && info.anchorName.isNotEmpty)
                      ? info.anchorName
                      : '直播间信息',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                if (info != null && info.title.isNotEmpty)
                  Text(
                    info.title,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: stateColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(stateText,
                        style: TextStyle(fontSize: 11, color: stateColor)),
                    if (_c.roomId > 0) ...[
                      const SizedBox(width: 8),
                      Text('房间 ${_c.roomId}',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 两个图标：点击 = 收藏/取消收藏当前房间；长按 = 进入批量管理。
          // 「角标数字」已按要求去掉，只靠图标本身的填充/描边表达是否已收藏。
          _favIcon(cs, Icons.favorite, Icons.favorite_border,
              const Color(0xFFF85149), _c.isFav('love'),
              () => _toggleFav('love'), () => _openManage('love')),
          const SizedBox(width: 2),
          _favIcon(cs, Icons.offline_bolt, Icons.offline_bolt_outlined,
              const Color(0xFFE3B341), _c.isFav('tech'),
              () => _toggleFav('tech'), () => _openManage('tech')),
          // 全屏模式下的退出按钮（也可直接按系统返回键退出）
          if (_c.danmakuFullscreen) ...[
            const SizedBox(width: 2),
            IconButton(
              tooltip: '退出全屏',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fullscreen_exit, size: 20),
              color: cs.onSurfaceVariant,
              onPressed: () => _c.setDanmakuFullscreen(false),
            ),
          ],
        ],
      ),
    );
  }

  /// 主播头像。数据来自直播间接口；拿不到时退化为昵称首字。
  Widget _anchorAvatar(ColorScheme cs) {
    final name = _c.info?.anchorName ?? '';
    final face = _c.info?.anchorFace ?? '';
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1B2129),
        border: Border.all(
          color: _c.state == ConnState.connected
              ? const Color(0xFF3FB950)
              : const Color(0xFF2A313B),
          width: 1.5,
        ),
      ),
      child: ClipOval(
        child: face.isNotEmpty
            ? Image.network(
                face,
                width: 42,
                height: 42,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, __, ___) => _avatarFallback(cs, name),
              )
            : _avatarFallback(cs, name),
      ),
    );
  }

  Widget _avatarFallback(ColorScheme cs, String name) {
    if (name.isEmpty) {
      return Icon(Icons.person_outline, size: 22, color: cs.onSurfaceVariant);
    }
    return Center(
      child: Text(
        name.substring(0, 1),
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// 爱播 / 技播图标：颜色规则 —— 只有已收藏当前房间才显示红/黄实心，
  /// 未收藏为灰色描边。不带角标数字。
  Widget _favIcon(
    ColorScheme cs,
    IconData filled,
    IconData outline,
    Color color,
    bool isFav,
    VoidCallback onTap,
    VoidCallback onLongPress,
  ) {
    return IconButton(
      onPressed: onTap,
      onLongPress: onLongPress,
      tooltip:
          isFav ? '取消收藏当前房间（长按批量管理）' : '收藏当前房间（长按批量管理）',
      icon: Icon(
        isFav ? filled : outline,
        color: isFav ? color : cs.onSurfaceVariant,
      ),
    );
  }

  /// 进场滚动提示：固定一条，多人进场时随时间轮换。
  Widget _buildEnterTicker(ColorScheme cs) {
    if (_c.enterQueue.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.login, size: 13, color: Color(0xFF6E7681)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _c.enterDisplay,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF8B949E)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme cs) {
    if (_c.roomId <= 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sensors_off,
                  size: 34, color: cs.onSurfaceVariant.withValues(alpha: .7)),
              const SizedBox(height: 14),
              Text(
                '还没有选择直播间',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                '到「传送门」输入房间号、粘贴分享链接，\n或从我的爱播 / 技播名单里选一个',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: cs.outline, fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
      );
    }
    final items = _c.visibleMessages;
    if (items.isEmpty) {
      final hint = switch (_c.state) {
        ConnState.connecting || ConnState.reconnecting => '正在连接…',
        ConnState.connected => '已连接，等待弹幕…',
        ConnState.error => '连接异常，正在重试…',
        ConnState.idle => '未连接',
      };
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_c.state == ConnState.connecting ||
                  _c.state == ConnState.reconnecting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: CircularProgressIndicator(),
                ),
              Text(hint, style: TextStyle(color: cs.onSurfaceVariant)),
              if (_c.error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _c.error!,
                    style: TextStyle(color: cs.error, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: items.length,
      padding: const EdgeInsets.symmetric(vertical: 6),
      // 新弹幕淡入 + 轻微上浮入场（复用 StaggerIn 的 index=0 无错峰形态）
      itemBuilder: (context, i) => StaggerIn(child: _buildRow(cs, items[i])),
    );
  }

  /// 用户标签小徽章（房管/年度/VIP/粉丝勋章/UL）。
  /// filled=true 实底白字，false 淡底描边同色字。
  WidgetSpan _tagSpan(String text, Color color, {bool filled = false}) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.only(right: 5),
        padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(4),
          border: filled
              ? null
              : Border.all(color: color.withValues(alpha: .45), width: .5),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 9.5,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: filled ? Colors.white : color,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, LiveEvent e) {
    final (Color color, IconData icon) = switch (e.kind) {
      EventKind.gift => (const Color(0xFFE3B341), Icons.card_giftcard),
      EventKind.guard => (const Color(0xFFA371F7), Icons.military_tech),
      EventKind.superchat => (const Color(0xFFF778BA), Icons.paid),
      EventKind.live => (const Color(0xFF3FB950), Icons.live_tv),
      _ => (const Color(0xFFE6EDF3), Icons.chat_bubble_outline),
    };
    final textColor = (e.kind == EventKind.gift ||
            e.kind == EventKind.guard ||
            e.kind == EventKind.superchat)
        ? color
        : null;
    final prefix = <InlineSpan>[];
    if (e.user.admin) {
      prefix.add(_tagSpan('房管', const Color(0xFFF85149), filled: true));
    } else if (e.user.svip) {
      prefix.add(_tagSpan('年度', const Color(0xFFE3B341), filled: true));
    } else if (e.user.vip) {
      prefix.add(_tagSpan('VIP', const Color(0xFFF778BA), filled: true));
    }
    if (e.user.hasMedal) {
      // 粉丝勋章：按等级给 B 站风格的勋章底色
      final lv = e.user.medalLevel;
      final medalColor = lv >= 10
          ? const Color(0xFFE3B341)
          : lv >= 7
              ? const Color(0xFFA371F7)
              : lv >= 4
                  ? const Color(0xFF3EC2A6)
                  : const Color(0xFF4FA0E0);
      prefix.add(_tagSpan('${e.user.medalName} $lv', medalColor, filled: true));
    }
    if (e.user.level > 0) {
      prefix.add(_tagSpan('UL${e.user.level}', const Color(0xFF6E7681)));
    }
    if (e.user.name.isNotEmpty) {
      prefix.add(TextSpan(
        text: '${e.user.name}：',
        style: const TextStyle(
          color: Color(0xFF85B7EB),
          fontWeight: FontWeight.w500,
        ),
      ));
    }
    final bodyStyle = const TextStyle(
        color: Color(0xFFE6EDF3), fontSize: 13.5, height: 1.45);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Icon(icon, size: 13, color: color.withValues(alpha: .7)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: bodyStyle,
                children: [
                  ...prefix,
                  ...buildEmojiSpans(
                    text: e.text,
                    style: textColor == null ? bodyStyle : TextStyle(
                        color: textColor, fontSize: 13.5, height: 1.45),
                    inline: e.emoticons,
                    room: _c.roomEmoji,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
