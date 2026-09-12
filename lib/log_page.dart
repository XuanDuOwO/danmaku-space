import 'package:flutter/material.dart';

import 'anim.dart';
import 'emoji_text.dart';
import 'relay_controller.dart';
import 'store.dart';

/// 弹幕记录（模块四）：**按直播间分类**的两级结构。
///
///   第一级（本页）：直播间列表 —— 主播头像 + 昵称 + 房间号，一条一个直播间；
///   第二级（点进去）：该直播间的历史弹幕，按日期（天）分组排列，
///     每个日期段可单独删除（删那一段时间的），
///     也可整间删除 —— 删完后第一级列表里这个直播间就消失了。
class LogTab extends StatefulWidget {
  const LogTab({
    super.key,
    required this.controller,
    required this.active,
  });

  final RelayController controller;

  /// 当前是否为选中的底部模块。从「非选中」变成「选中」时重载一次，
  /// 保证看到的是刚落盘的最新内容。
  final bool active;

  @override
  State<LogTab> createState() => _LogTabState();
}

/// 一个直播间的汇总信息（第一级列表的一行）。
class _RoomSummary {
  int roomId = 0;
  String anchor = '';
  String anchorFace = '';
  int count = 0;
  int lastTs = 0;
  final Set<String> days = {};
}

class _LogTabState extends State<LogTab> {
  /// 房间号 → 汇总。
  Map<int, _RoomSummary> _rooms = {};

  /// 房间号 → 该房间表情表，用于回放历史里的灯牌/通用表情。
  Map<String, Map<String, String>> _tables = {};

  int _total = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.controller.logRevision.addListener(_onRevision);
    _reload();
  }

  @override
  void didUpdateWidget(covariant LogTab old) {
    super.didUpdateWidget(old);
    if (!old.active && widget.active) _reload();
  }

  @override
  void dispose() {
    widget.controller.logRevision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    // 只有正看着这一页才需要刷新，避免后台空转。
    if (widget.active) _reload();
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    await widget.controller.flushLog();
    final logs = await Store.loadAllLogs();
    final tables = await Store.loadAllEmojiTables();
    if (!mounted) return;

    final rooms = <int, _RoomSummary>{};
    var total = 0;
    // 日期倒序遍历（loadAllLogs 已保证），后遇到的更新 → 自动取到最新的昵称/头像。
    for (final entry in logs.entries) {
      final day = entry.key;
      for (final e in entry.value) {
        final s = rooms.putIfAbsent(e.roomId, () => _RoomSummary()
          ..roomId = e.roomId);
        if (e.anchor.isNotEmpty) s.anchor = e.anchor;
        if (e.anchorFace.isNotEmpty) s.anchorFace = e.anchorFace;
        s.count++;
        s.days.add(day);
        if (e.ts > s.lastTs) s.lastTs = e.ts;
        total++;
      }
    }
    setState(() {
      _rooms = rooms;
      _tables = tables;
      _total = total;
      _loading = false;
    });
  }

  List<_RoomSummary> get _roomList {
    final list = _rooms.values.toList();
    list.sort((a, b) => b.lastTs.compareTo(a.lastTs)); // 最近有弹幕的在上
    return list;
  }

  // ---------------------------------------------------------------- 动作

  Future<void> _openRoom(_RoomSummary s) async {
    await widget.controller.flushLog();
    if (!mounted) return;
    await Navigator.of(context).push(
      FadeSlideRoute(RoomLogPage(
        roomId: s.roomId,
        anchor: s.anchor,
        anchorFace: s.anchorFace,
        tables: _tables,
        controller: widget.controller,
      )),
    );
    // 从第二级回来后重载：整间删除后这行要消失。
    _reload();
  }

  Future<void> _clearAll() async {
    if (_total == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空弹幕记录'),
        content: Text('确定删除全部 $_total 条记录（所有直播间）？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Store.clearAllLogs();
    await _reload();
    if (mounted) _snack('已清空');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  // ---------------------------------------------------------------- 格式化

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtLast(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final day = LogEntry.dayOf(ms);
    final today = LogEntry.dayOf(now.millisecondsSinceEpoch);
    final yest = LogEntry
        .dayOf(now.subtract(const Duration(days: 1)).millisecondsSinceEpoch);
    final hhmm = '${_two(d.hour)}:${_two(d.minute)}';
    if (day == today) return '今天 $hhmm';
    if (day == yest) return '昨天 $hhmm';
    return '${d.month}-${_two(d.day)} $hhmm';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rooms = _roomList;
    return Scaffold(
      appBar: AppBar(
        title: const Text('弹幕记录', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: '清空全部',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _total == 0 ? null : _clearAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : rooms.isEmpty
              ? _empty(cs)
              : Column(
                  children: [
                    _summaryCard(cs),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        // 见 home_page.dart 的说明：避免与其它模块共用
                        // PrimaryScrollController 导致切模块时位置串掉。
                        primary: false,
                        padding: const EdgeInsets.only(bottom: 40),
                        itemCount: rooms.length,
                        itemBuilder: (_, i) => StaggerIn(
                          index: i > 3 ? 4 : i,
                          child: _roomRow(cs, rooms[i]),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _summaryCard(ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF11161D),
        border: Border(bottom: BorderSide(color: Color(0xFF222831))),
      ),
      child: Text(
        '已记录 ${_rooms.length} 个直播间 · 共 $_total 条'
        '${widget.controller.todayLogged > 0 ? ' · 今日 ${widget.controller.todayLogged} 条' : ''}'
        '，点进任意直播间查看与删除',
        style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _roomRow(ColorScheme cs, _RoomSummary s) {
    final fallback =
        s.anchor.isNotEmpty ? s.anchor[0] : '${s.roomId}';
    return InkWell(
      onTap: () => _openRoom(s),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF1B2129))),
        ),
        child: Row(
          children: [
            // 主播头像
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1B2129),
                border: Border.all(color: const Color(0xFF2C3440), width: 1),
              ),
              child: ClipOval(
                child: s.anchorFace.isNotEmpty
                    ? Image.network(
                        s.anchorFace,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Center(
                          child: Text(fallback,
                              style: const TextStyle(fontSize: 15)),
                        ),
                      )
                    : Center(
                        child: Text(fallback,
                            style: const TextStyle(fontSize: 15)),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.anchor.isNotEmpty ? s.anchor : '房间 ${s.roomId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '房间号 ${s.roomId} · ${s.days.length} 天 / ${s.count} 条'
                    '${s.lastTs > 0 ? ' · 最近 ${_fmtLast(s.lastTs)}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: cs.outline),
          ],
        ),
      ),
    );
  }

  Widget _empty(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 34, color: cs.onSurfaceVariant.withValues(alpha: .7)),
            const SizedBox(height: 14),
            Text('还没有弹幕记录',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
            const SizedBox(height: 6),
            Text(
              '到「传送门」进入任意直播间后，\n收到的每条弹幕都会按直播间留档在这里',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.outline, fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================================
// 第二级：单个直播间的历史弹幕，按日期分组；可删某一天，也可整间删除。
// ======================================================================

class RoomLogPage extends StatefulWidget {
  const RoomLogPage({
    super.key,
    required this.roomId,
    required this.anchor,
    required this.anchorFace,
    required this.tables,
    required this.controller,
  });

  final int roomId;
  final String anchor;
  final String anchorFace;

  /// 房间号 → 表情表（含本房间）。
  final Map<String, Map<String, String>> tables;

  final RelayController controller;

  @override
  State<RoomLogPage> createState() => _RoomLogPageState();
}

class _RoomLogPageState extends State<RoomLogPage> {
  /// 日期 → 该天本房间的条目（时间正序）。
  Map<String, List<LogEntry>> _logs = {};

  bool _loading = true;

  static const _kindColor = <String, Color>{
    'danmaku': Color(0xFF8AB4F8),
    'gift': Color(0xFFF0A868),
    'guard': Color(0xFFE3B341),
    'superchat': Color(0xFFF85149),
    'system': Color(0xFF9AA4B2),
    'live': Color(0xFF7BD88F),
  };

  static const _kindLabel = <String, String>{
    'danmaku': '弹幕',
    'gift': '礼物',
    'guard': '舰长',
    'superchat': 'SC',
    'system': '系统',
    'live': '开播',
  };

  @override
  void initState() {
    super.initState();
    widget.controller.logRevision.addListener(_onRevision);
    _reload();
  }

  @override
  void dispose() {
    widget.controller.logRevision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    await widget.controller.flushLog();
    final all = await Store.loadAllLogs();
    if (!mounted) return;
    final out = <String, List<LogEntry>>{};
    for (final entry in all.entries) {
      final list =
          entry.value.where((e) => e.roomId == widget.roomId).toList();
      if (list.isNotEmpty) out[entry.key] = list;
    }
    setState(() {
      _logs = out;
      _loading = false;
    });
  }

  int get _total => _logs.values.fold<int>(0, (n, l) => n + l.length);

  // ---------------------------------------------------------------- 删除

  /// 删除某一天（那一段时间）的记录。
  Future<void> _deleteDay(String day) async {
    final n = _logs[day]?.length ?? 0;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${_dayLabel(day)} 的记录'),
        content: Text('确定删除该直播间 $day 当天的 $n 条记录？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = <int>{
      for (final e in (_logs[day] ?? const <LogEntry>[])) e.id,
    };
    widget.controller.dropPending(ids);
    await Store.deleteRoomDay(widget.roomId, day);
    await _reload();
    if (mounted) _snack('已删除 $n 条');
  }

  /// 整间删除：删完后第一级列表里这个直播间也会消失。
  Future<void> _deleteRoom() async {
    if (_total == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该直播间的全部记录'),
        content:
            Text('确定删除「${_title}」的全部 $_total 条记录？\n删除后弹幕记录列表里将不再显示该直播间。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = <int>{
      for (final l in _logs.values) ...l.map((e) => e.id),
    };
    widget.controller.dropPending(ids);
    await Store.deleteRoomAll(widget.roomId);
    if (mounted) {
      _snack('已删除该直播间的全部记录');
      Navigator.of(context).pop(); // 回到第一级列表（会自动重载）
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  // ---------------------------------------------------------------- 格式化

  String get _title => widget.anchor.isNotEmpty
      ? widget.anchor
      : '房间 ${widget.roomId}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
  }

  static const _week = ['一', '二', '三', '四', '五', '六', '日'];

  static String _dayLabel(String day) {
    final t = DateTime.now();
    final today = LogEntry.dayOf(t.millisecondsSinceEpoch);
    final yest = LogEntry
        .dayOf(t.subtract(const Duration(days: 1)).millisecondsSinceEpoch);
    if (day == today) return '今天';
    if (day == yest) return '昨天';
    final d = DateTime.tryParse(day);
    if (d == null) return day;
    return '${d.month}月${d.day}日 周${_week[d.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final days = _logs.keys.toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_title, style: const TextStyle(fontSize: 16)),
            Text('房间号 ${widget.roomId} · 共 $_total 条',
                style: TextStyle(
                    fontSize: 10.5, color: cs.onSurfaceVariant, height: 1.2)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '删除该直播间全部记录',
            icon: const Icon(Icons.delete_forever_outlined),
            onPressed: _total == 0 ? null : _deleteRoom,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _total == 0
              ? Center(
                  child: Text('该直播间暂无记录',
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 13)),
                )
              : ListView.builder(
                  primary: false,
                  padding: const EdgeInsets.only(bottom: 40),
                  itemCount: days.length,
                  itemBuilder: (_, i) {
                    final day = days[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _dayHeader(cs, day),
                        ..._logs[day]!.map((e) => _row(cs, e)),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _dayHeader(ColorScheme cs, String day) {
    final n = _logs[day]?.length ?? 0;
    return Container(
      color: const Color(0xFF0B0E13),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      child: Row(
        children: [
          Icon(Icons.event_note, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            '${_dayLabel(day)}  ($day)',
            style: TextStyle(
              fontSize: 12.5,
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text('$n 条', style: TextStyle(fontSize: 11, color: cs.outline)),
          IconButton(
            tooltip: '删除这一天的记录',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 17),
            color: cs.outline,
            onPressed: () => _deleteDay(day),
          ),
        ],
      ),
    );
  }

  Widget _row(ColorScheme cs, LogEntry e) {
    final color = _kindColor[e.kind] ?? cs.onSurfaceVariant;
    final room = widget.tables['${e.roomId}'];
    final bodyStyle = TextStyle(color: cs.onSurface, fontSize: 12.5, height: 1.45);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 7, 12, 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF171C24))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _fmtTime(e.ts),
            style: const TextStyle(
              fontSize: 10.5,
              color: Color(0xFF6E7681),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(_kindLabel[e.kind] ?? '弹幕',
                style: TextStyle(fontSize: 9.5, color: color)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: bodyStyle,
                children: [
                  if (e.user.isNotEmpty)
                    TextSpan(
                      text: '${e.user}：',
                      style: TextStyle(color: Color(0xFF85B7EB)),
                    ),
                  ...buildEmojiSpans(
                    text: e.text,
                    style: bodyStyle,
                    inline: e.emo,
                    room: room,
                    height: 16,
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
