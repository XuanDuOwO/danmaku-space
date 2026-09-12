import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地存储：登录态、上次房间、爱播/技播收藏、弹幕记录、房间表情表、最近观看。

/// 收藏的直播间（爱播 / 技播）。type: 'love' | 'tech'
class FavRoom {
  final int roomId;
  final String name;
  final String face;
  final String type;

  const FavRoom({
    required this.roomId,
    this.name = '',
    this.face = '',
    this.type = 'love',
  });

  Map<String, dynamic> toJson() => {
        'roomId': roomId,
        'name': name,
        'face': face,
        'type': type,
      };

  factory FavRoom.fromJson(Map<String, dynamic> j) => FavRoom(
        roomId: (j['roomId'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '',
        face: (j['face'] as String?) ?? '',
        type: (j['type'] as String?) ?? 'love',
      );
}

/// 最近观看过的直播间（传送门页展示，只为省一次手输）。
class RecentRoom {
  final int roomId;
  final String name;
  final String face;
  final int ts;

  const RecentRoom({
    required this.roomId,
    this.name = '',
    this.face = '',
    this.ts = 0,
  });

  Map<String, dynamic> toJson() =>
      {'roomId': roomId, 'name': name, 'face': face, 'ts': ts};

  factory RecentRoom.fromJson(Map<String, dynamic> j) => RecentRoom(
        roomId: (j['roomId'] as num?)?.toInt() ?? 0,
        name: (j['name'] as String?) ?? '',
        face: (j['face'] as String?) ?? '',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
      );
}

/// 一条弹幕记录：**跨主播、跨会话**持久化保存。
/// 字段名刻意压到最短，因为这个对象会被大量序列化进 SharedPreferences。
class LogEntry {
  /// 全局自增 id，删除时用它定位（不能靠下标，因为后台仍在追加新条目）。
  final int id;
  final int ts;
  final int roomId;

  /// 记录时的主播昵称 / 头像快照（房间号复用时也能看出是谁）。
  final String anchor;
  final String anchorFace;
  final String user;
  final String text;

  /// EventKind.name，避免再引入枚举依赖。
  final String kind;

  /// 本条弹幕自带的表情表（token → URL）。
  final Map<String, String> emo;

  const LogEntry({
    required this.id,
    required this.ts,
    required this.roomId,
    this.anchor = '',
    this.anchorFace = '',
    this.user = '',
    this.text = '',
    this.kind = 'danmaku',
    this.emo = const {},
  });

  Map<String, dynamic> toJson() => {
        'i': id,
        't': ts,
        'r': roomId,
        if (anchor.isNotEmpty) 'a': anchor,
        if (anchorFace.isNotEmpty) 'f': anchorFace,
        if (user.isNotEmpty) 'u': user,
        'x': text,
        'k': kind,
        if (emo.isNotEmpty) 'e': emo,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: (j['i'] as num?)?.toInt() ?? 0,
        ts: (j['t'] as num?)?.toInt() ?? 0,
        roomId: (j['r'] as num?)?.toInt() ?? 0,
        anchor: (j['a'] as String?) ?? '',
        anchorFace: (j['f'] as String?) ?? '',
        user: (j['u'] as String?) ?? '',
        text: (j['x'] as String?) ?? '',
        kind: (j['k'] as String?) ?? 'danmaku',
        emo: j['e'] is Map
            ? (j['e'] as Map).map((k, v) => MapEntry('$k', '$v'))
            : const {},
      );

  /// 所属日期（本地时区），形如 `2026-09-12`。
  String get day => dayOf(ts);

  static String dayOf(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class Store {
  static const _kCookie = 'bili_cookie';
  static const _kRoom = 'room_id';
  static const _kFav = 'fav_rooms';
  static const _kSeq = 'log_seq';
  static const _kRecent = 'recent_rooms';
  static const _kEmojiOrder = 'emoji_room_order';
  static const _logPrefix = 'dlog_';
  static const _emojiPrefix = 'etab_';

  /// 弹幕记录保留天数、表情表保留房间数。
  static const int logKeepDays = 30;
  static const int emojiKeepRooms = 30;
  static const int recentMax = 12;

  // ------------------------------------------------------------------ 登录态

  static Future<String> loadCookie() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kCookie) ?? '';
  }

  static Future<void> saveCookie(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCookie, v);
  }

  static Future<void> clearCookie() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kCookie);
  }

  // ------------------------------------------------------------ 上次/最近房间

  static Future<int> loadRoomId() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kRoom) ?? 0;
  }

  static Future<void> saveRoomId(int v) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kRoom, v);
  }

  static Future<List<RecentRoom>> loadRecent() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kRecent);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(RecentRoom.fromJson)
          .where((e) => e.roomId > 0)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 把房间置顶到「最近观看」。主播名/头像为空时不覆盖已有值。
  static Future<List<RecentRoom>> touchRecent(int roomId,
      {String name = '', String face = ''}) async {
    if (roomId <= 0) return [];
    final list = await loadRecent();
    final idx = list.indexWhere((e) => e.roomId == roomId);
    if (idx >= 0) {
      final old = list.removeAt(idx);
      list.insert(
        0,
        RecentRoom(
          roomId: roomId,
          name: name.isNotEmpty ? name : old.name,
          face: face.isNotEmpty ? face : old.face,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else {
      list.insert(
        0,
        RecentRoom(
          roomId: roomId,
          name: name,
          face: face,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    while (list.length > recentMax) {
      list.removeLast();
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kRecent, jsonEncode(list.map((e) => e.toJson()).toList()));
    return list;
  }

  /// 清空「最近观看」。
  static Future<void> clearRecent() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kRecent);
  }

  // ------------------------------------------------------------------ 收藏

  static Future<List<FavRoom>> loadFavorites() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kFav);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(FavRoom.fromJson)
          .where((f) => f.roomId > 0)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveFavorites(List<FavRoom> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kFav,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  // -------------------------------------------------------------- 弹幕记录

  /// 先调一次以载入自增序列，之后 [reserveLogId] 可同步取值。
  static Future<void> initLogSeq() async {
    if (_seqLoaded) return;
    final p = await SharedPreferences.getInstance();
    _seq = p.getInt(_kSeq) ?? 0;
    _seqLoaded = true;
  }

  static int _seq = 0;
  static bool _seqLoaded = false;

  /// 预留一个日志 id（同步）。持久化在 [saveLogDay] 里一并落盘。
  static int reserveLogId() => ++_seq;

  /// 覆盖写入某一天的日志。[list] 必须是该天的完整列表。
  static Future<void> saveLogDay(String day, List<LogEntry> list) async {
    final p = await SharedPreferences.getInstance();
    if (list.isEmpty) {
      await p.remove('$_logPrefix$day');
    } else {
      await p.setString(
        '$_logPrefix$day',
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
    }
    await p.setInt(_kSeq, _seq);
  }

  /// 已记录的日期列表（**按时间倒序**，最新的在前）。
  static Future<List<String>> logDays() async {
    final p = await SharedPreferences.getInstance();
    final days = p
        .getKeys()
        .where((k) => k.startsWith(_logPrefix))
        .map((k) => k.substring(_logPrefix.length))
        .where((d) => d.length == 10)
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return days;
  }

  static Future<List<LogEntry>> loadLogDay(String day) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('$_logPrefix$day');
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(LogEntry.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 读取全部日期的弹幕记录：返回 日期 → 条目（日期倒序，日内按时间正序）。
  static Future<Map<String, List<LogEntry>>> loadAllLogs() async {
    final out = <String, List<LogEntry>>{};
    for (final d in await logDays()) {
      final list = await loadLogDay(d);
      if (list.isNotEmpty) out[d] = list;
    }
    return out;
  }

  /// 删除指定 id 的条目（按天分组写回）。返回删除条数。
  static Future<int> deleteLogEntries(Set<int> ids) async {
    if (ids.isEmpty) return 0;
    var removed = 0;
    for (final day in await logDays()) {
      final list = await loadLogDay(day);
      final keep = list.where((e) => !ids.contains(e.id)).toList();
      if (keep.length != list.length) {
        removed += list.length - keep.length;
        await saveLogDay(day, keep);
      }
    }
    return removed;
  }

  /// 删除某直播间某一天的全部记录（按天文件过滤写回）。返回删除条数。
  static Future<int> deleteRoomDay(int roomId, String day) async {
    final list = await loadLogDay(day);
    final keep = list.where((e) => e.roomId != roomId).toList();
    if (keep.length == list.length) return 0;
    await saveLogDay(day, keep);
    return list.length - keep.length;
  }

  /// 删除某直播间的全部记录（跨所有日期）。
  /// 天文件因此变空的会被整个移除。返回删除条数。
  static Future<int> deleteRoomAll(int roomId) async {
    var removed = 0;
    for (final day in await logDays()) {
      removed += await deleteRoomDay(roomId, day);
    }
    return removed;
  }

  /// 清空全部弹幕记录。
  static Future<void> clearAllLogs() async {
    final p = await SharedPreferences.getInstance();
    for (final k in p.getKeys().where((k) => k.startsWith(_logPrefix)).toList()) {
      await p.remove(k);
    }
  }

  /// 只保留最近 [logKeepDays] 天，避免无限增长。
  static Future<void> pruneLogs() async {
    final days = await logDays();
    if (days.length <= logKeepDays) return;
    final p = await SharedPreferences.getInstance();
    for (final d in days.sublist(logKeepDays)) {
      await p.remove('$_logPrefix$d');
    }
  }

  // ------------------------------------------------------------ 房间表情表

  /// 缓存某房间的表情表（token → 图片 URL），供弹幕记录页回放历史表情。
  static Future<void> saveEmojiTable(
      int roomId, Map<String, String> table) async {
    if (roomId <= 0 || table.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('$_emojiPrefix$roomId', jsonEncode(table));

    // 维护房间顺序，超出上限就把最旧的连同数据一起删掉。
    final order = (p.getStringList(_kEmojiOrder) ?? [])
        .where((e) => e != '$roomId')
        .toList();
    order.insert(0, '$roomId');
    while (order.length > emojiKeepRooms) {
      final old = order.removeLast();
      await p.remove('$_emojiPrefix$old');
    }
    await p.setStringList(_kEmojiOrder, order);
  }

  static Future<Map<String, Map<String, String>>> loadAllEmojiTables() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, Map<String, String>>{};
    for (final k in p.getKeys().where((k) => k.startsWith(_emojiPrefix))) {
      final raw = p.getString(k);
      if (raw == null || raw.isEmpty) continue;
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        out[k.substring(_emojiPrefix.length)] =
            m.map((a, b) => MapEntry(a, '$b'));
      } catch (_) {
        // 单条坏了就跳过，不影响其它房间
      }
    }
    return out;
  }
}
