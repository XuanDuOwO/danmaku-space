import 'package:flutter/material.dart';

import '../../blive/audience.dart';
import '../../blive/gift.dart';
import '../../state/relay_controller.dart';
import '../anim.dart';
import '../theme.dart';

/// 「观众礼物」模块：两个标签页。
///
///   实时观众 —— 当前在线人数 + 高能榜观众头像列表
///   礼物价值 —— 本场礼物的单价表与价值总汇总
///
/// 之所以把观众和礼物合成一个模块：它们回答的是同一类问题
/// （「这个直播间现在什么情况」），而底部导航放四个以上的标签已经很挤。
class GiftTab extends StatefulWidget {
  const GiftTab({super.key, required this.controller});

  final RelayController controller;

  @override
  State<GiftTab> createState() => _GiftTabState();
}

class _GiftTabState extends State<GiftTab> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  RelayController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // 观众数据的后台轮询在弹幕空间页也会跑；这里保持开启，
    // 保证切到这个模块时数字是热的。
    _c.audienceAutoRefresh = true;
    _c.addListener(_onChanged);
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('观众礼物', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: '刷新观众数据',
            icon: const Icon(Icons.refresh),
            onPressed: _c.audienceLoading ? null : _c.refreshAudience,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '实时观众'),
            Tab(text: '礼物价值'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _AudiencePane(controller: _c),
          _GiftPane(controller: _c),
        ],
      ),
    );
  }
}

// ======================================================================
// 实时观众
// ======================================================================

/// 从弹幕空间页点「在线 N 人」推进来的独立页面。
///
/// 和「观众礼物」模块里的「实时观众」标签页是同一份内容（复用
/// [_AudiencePane]），只是多包一层 Scaffold 便于 push。
class AudienceDetailPage extends StatelessWidget {
  const AudienceDetailPage({super.key, required this.controller});

  final RelayController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = controller.info?.anchorName ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('实时观众', style: TextStyle(fontSize: 16)),
            Text(
              name.isNotEmpty ? name : '房间 ${controller.roomId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed:
                controller.audienceLoading ? null : controller.refreshAudience,
          ),
        ],
      ),
      body: _AudiencePane(controller: controller),
    );
  }
}

class _AudiencePane extends StatelessWidget {
  const _AudiencePane({required this.controller});

  final RelayController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final online = controller.audienceOnline;
    final members = controller.audienceMembers;

    return RefreshIndicator(
      onRefresh: controller.refreshAudience,
      child: CustomScrollView(
        primary: false,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _header(cs, online)),
          if (controller.audienceError != null)
            SliverToBoxAdapter(
                child: _errorBar(cs, controller.audienceError!)),
          if (members.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: _empty(cs))
          else ...[
            SliverToBoxAdapter(child: _listHeader(cs, members.length)),
            SliverList.builder(
              itemCount: members.length,
              itemBuilder: (_, i) => StaggerIn(
                index: i > 4 ? 4 : i,
                child: _row(cs, members[i]),
              ),
            ),
            SliverToBoxAdapter(child: _footer(cs)),
          ],
        ],
      ),
    );
  }

  Widget _header(ColorScheme cs, int online) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 26, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前在线',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _fmtCount(online),
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('人',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    if (controller.audienceLoading) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '每 ${RelayController.audienceInterval.inSeconds} 秒自动刷新',
                style: TextStyle(fontSize: 10, color: cs.outline),
              ),
              const SizedBox(height: 4),
              Text(
                '${controller.audienceMembers.length} 人在高能榜',
                style: TextStyle(fontSize: 10.5, color: cs.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _listHeader(ColorScheme cs, int n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Icon(Icons.leaderboard_outlined, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            '高能榜',
            style: TextStyle(
              fontSize: 12,
              color: cs.primary,
              fontWeight: FontWeight.w600,
              letterSpacing: .3,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              controller.audienceTips.isNotEmpty
                  ? controller.audienceTips
                  : '投喂、点赞、发弹幕均可上榜',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: cs.outline),
            ),
          ),
          Text('$n 人', style: TextStyle(fontSize: 10.5, color: cs.outline)),
        ],
      ),
    );
  }

  Widget _errorBar(ColorScheme cs, String msg) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.error.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 15, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '观众数据获取失败：$msg',
              style: TextStyle(fontSize: 11.5, color: cs.error, height: 1.5),
            ),
          ),
          GestureDetector(
            onTap: controller.refreshAudience,
            child: Text(
              '重试',
              style: TextStyle(
                fontSize: 11.5,
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme cs) {
    final loading = controller.audienceLoading;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: CircularProgressIndicator(),
              )
            else
              Icon(Icons.people_outline,
                  size: 34, color: cs.onSurfaceVariant.withValues(alpha: .7)),
            const SizedBox(height: 14),
            Text(
              loading ? '正在获取观众数据…' : '暂无上榜观众',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              '高能榜只收录在直播间投喂 / 点赞 / 发过弹幕的人。\n'
              '刚进直播间时可能还没有人上榜，稍等片刻会自动刷新。',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.outline, fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(ColorScheme cs) {
    if (controller.audienceHasMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed:
                controller.audienceLoading ? null : controller.loadMoreAudience,
            icon: controller.audienceLoading
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.expand_more, size: 18),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Text(
        '高能榜只列出有贡献值的观众，条数通常少于在线人数；\n'
        'B站不提供完整观众名册，因此这里看不到全部观众的头像。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 10.5, color: cs.outline, height: 1.6),
      ),
    );
  }

  Widget _row(ColorScheme cs, AudienceMember m) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderFaint)),
      ),
      child: Row(
        children: [
          _rank(cs, m),
          const SizedBox(width: 10),
          _avatar(cs, m),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        m.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (m.guardLabel.isNotEmpty) ...[
                      const SizedBox(width: 5),
                      _tag(m.guardLabel, _guardColor(m.guardLevel),
                          filled: true),
                    ],
                    if (m.hasMedal) ...[
                      const SizedBox(width: 5),
                      _tag('${m.medalName} ${m.medalLevel}',
                          const Color(0xFF3EC2A6)),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '贡献值 ${_fmtCount(m.score)}'
                  '${m.wealthLevel > 0 ? ' · 荣耀 ${m.wealthLevel}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: cs.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 名次徽章：前三名用金银铜，其余显示灰色序号。
  Widget _rank(ColorScheme cs, AudienceMember m) {
    if (m.rank <= 0) return const SizedBox(width: 24);
    final color = switch (m.rank) {
      1 => AppColors.gift,
      2 => const Color(0xFFAAB4C0),
      3 => const Color(0xFFCE8B5A),
      _ => const Color(0xFF39414D),
    };
    return Container(
      width: 24,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: m.rank <= 3 ? .22 : 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${m.rank}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: m.rank <= 3 ? color : cs.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _avatar(ColorScheme cs, AudienceMember m) {
    // 昵称首字兜底，用 characters 取「字素簇」而不是 substring，
    // 否则以 emoji 开头的昵称会被截成半个代理对，渲染成方块。
    final fallback =
        m.name.isNotEmpty ? m.name.characters.first : '${m.uid % 100}';
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surfaceHighlight,
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: ClipOval(
        child: m.face.isNotEmpty
            ? Image.network(
                m.face,
                width: 34,
                height: 34,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => Center(
                  child: Text(fallback, style: const TextStyle(fontSize: 13)),
                ),
              )
            : Center(
                child: Text(fallback, style: const TextStyle(fontSize: 13)),
              ),
      ),
    );
  }

  static Color _guardColor(int level) => switch (level) {
        1 => AppColors.danger, // 总督
        2 => AppColors.superchat, // 提督
        _ => AppColors.guard, // 舰长
      };

  Widget _tag(String text, Color color, {bool filled = false}) {
    return Container(
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
    );
  }
}

// ======================================================================
// 礼物价值
// ======================================================================

class _GiftPane extends StatefulWidget {
  const _GiftPane({required this.controller});

  final RelayController controller;

  @override
  State<_GiftPane> createState() => _GiftPaneState();
}

class _GiftPaneState extends State<_GiftPane> {
  /// 「只看付费」开关。默认打开 —— 免费礼物（辣条等）数量巨大但没有金额，
  /// 混在一起会把金额表刷得看不清。
  bool _paidOnly = true;

  RelayController get _c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _c.giftSummary;
    final items = _paidOnly ? s.paidItems : s.items;

    return ListView(
      primary: false,
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _totalCard(cs, s),
        _section(cs, '本场送礼明细'),
        if (s.items.isEmpty)
          _empty(cs)
        else ...[
          _toggleRow(cs, s),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
              child: Text(
                '本场还没有付费礼物',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
            )
          else
            ...items.map((e) => _giftRow(cs, e)),
        ],
        if (_c.giftTable.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Text(
              _c.roomId > 0
                  ? '礼物价格表尚未加载完成，金额可能暂时显示为 ¥0。'
                  : '还没有连接直播间。',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.6),
            ),
          ),
      ],
    );
  }

  Widget _totalCard(ColorScheme cs, GiftSummary s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, size: 22, color: AppColors.gift),
              const SizedBox(width: 10),
              Text('本场礼物价值',
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const Spacer(),
              // 手动清零：口径是「本次连接期间」，重连会自己清。
              if (!s.isEmpty)
                TextButton(
                  onPressed: _confirmReset,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('清零', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            formatYuan(s.totalYuan),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _stat(cs, '付费礼物', '${s.paidCount} 个'),
              _stat(cs, '免费礼物', '${s.freeCount} 个'),
              _stat(cs, '礼物种类', '${s.items.length} 种'),
              if (s.unknownCount > 0)
                _stat(cs, '未知价格', '${s.unknownCount} 条',
                    color: AppColors.warning),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '口径：本次连接期间收到的礼物（B站不提供「本场开播至今」的接口）。'
            '断线重连或换房间会重新计。1000 金瓜子 = ¥1。',
            style: TextStyle(fontSize: 10.5, color: cs.outline, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _stat(ColorScheme cs, String label, String value, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: color ?? cs.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _toggleRow(ColorScheme cs, GiftSummary s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Row(
        children: [
          Text(
            '共 ${s.items.length} 种礼物',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
          const Spacer(),
          Text('只看付费',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
          Switch(
            value: _paidOnly,
            onChanged: (v) => setState(() => _paidOnly = v),
          ),
        ],
      ),
    );
  }

  Widget _giftRow(ColorScheme cs, GiftTally g) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 9, 14, 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderFaint)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'x${g.count}',
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  g.paid
                      ? '单价 ${formatYuan(g.unitPrice / goldBeansPerYuan)}'
                          '${g.maxBatch > 1 ? ' · 单次最多 x${g.maxBatch}' : ''}'
                      : '免费礼物',
                  style: TextStyle(fontSize: 10.5, color: cs.outline),
                ),
              ],
            ),
          ),
          Text(
            g.paid ? formatYuan(g.yuan) : '—',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: g.paid ? AppColors.gift : cs.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(ColorScheme cs, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
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

  Widget _empty(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
      child: Column(
        children: [
          Icon(Icons.card_giftcard_outlined,
              size: 34, color: cs.onSurfaceVariant.withValues(alpha: .7)),
          const SizedBox(height: 14),
          Text('本场还没有收到礼物',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
          const SizedBox(height: 6),
          Text(
            '到「传送门」进入直播间后，收到的每个礼物都会按面板单价折算成金额，'
            '在这里汇总。',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.outline, fontSize: 12, height: 1.6),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清零本场统计'),
        content: const Text('确定把当前累计的礼物金额与数量清零？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清零'),
          ),
        ],
      ),
    );
    if (ok == true) _c.clearGiftSummary();
  }
}

/// 人数 / 贡献值的紧凑格式：10000 → 1.0万，1亿 → 1.0亿。
String _fmtCount(int v) {
  if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
  if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
  return '$v';
}
