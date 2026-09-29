import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地存储：登录态、上次房间、爱播/技播收藏、房间表情表、最近观看。
///
/// 注意：这里**不再**保存弹幕记录。按天把每条弹幕序列化进 SharedPreferences
/// 需要每 5 秒重写整天的 JSON，房间一热闹就是持续的重 IO，
/// 收益却只是「回看历史弹幕」—— 该功能已整体移除。

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

/// 一条弹幕记录。
///
/// **已废弃**：弹幕持久化功能整体移除（每 5 秒重写整天 JSON 太耗性能）。
/// 这个类暂时保留，只是为了让曾经写进 SharedPreferences 的 `dlog_*` 旧数据
/// 能被 [Store.purgeLegacyLogs] 识别并清掉，新版本不再写入。
@Deprecated('弹幕存储已移除，仅用于清理历史遗留数据')
class LogEntry {
  final int ts;
  final int roomId;
  final String user;
  final String text;
  final String kind;

  const LogEntry({
    required this.ts,
    required this.roomId,
    this.user = '',
    this.text = '',
    this.kind = 'danmaku',
  });

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        ts: (j['t'] as num?)?.toInt() ?? 0,
        roomId: (j['r'] as num?)?.toInt() ?? 0,
        user: (j['u'] as String?) ?? '',
        text: (j['x'] as String?) ?? '',
        kind: (j['k'] as String?) ?? 'danmaku',
      );
}

class Store {
  static const _kCookie = 'bili_cookie';
  static const _kRoom = 'room_id';
  static const _kFav = 'fav_rooms';
  static const _kRecent = 'recent_rooms';
  static const _kEmojiOrder = 'emoji_room_order';
  static const _kFsTopOffset = 'fs_top_offset';
  static const _kFsLeftOffset = 'fs_left_offset';

  /// 表情表与「已废弃的弹幕记录」用的前缀。
  static const _emojiPrefix = 'etab_';

  /// 旧版本写弹幕记录用的 key 前缀（`dlog_<日期>`）与自增序列 key。
  /// 新版本不再写入，只在启动时清理一次。
  static const _legacyLogPrefix = 'dlog_';
  static const _legacySeqKey = 'log_seq';

  /// 表情表保留房间数。
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

  // -------------------------------------------------- 历史数据清理

  /// 清理旧版本遗留的弹幕记录。
  ///
  /// 弹幕持久化已整体移除（每 5 秒重写整天 JSON 太重），
  /// 但老用户设备上可能还留着 `dlog_*` 与 `log_seq`，
  /// 启动时顺手删掉，把被占的存储还给系统。
  static Future<void> purgeLegacyLogs() async {
    final p = await SharedPreferences.getInstance();
    final keys = p
        .getKeys()
        .where((k) => k.startsWith(_legacyLogPrefix) || k == _legacySeqKey)
        .toList();
    for (final k in keys) {
      await p.remove(k);
    }
  }

  // ------------------------------------------------- 全屏挖孔避让偏移（手动可调）

  /// 竖屏全屏：直播间信息条顶部避让偏移；横屏全屏：弹幕起始左侧偏移。
  static Future<double> loadFsOffset({required bool landscape}) async {
    final p = await SharedPreferences.getInstance();
    return p.getDouble(landscape ? _kFsLeftOffset : _kFsTopOffset) ??
        (landscape ? 48.0 : 96.0);
  }

  static Future<void> saveFsOffset(double v, {required bool landscape}) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(landscape ? _kFsLeftOffset : _kFsTopOffset, v);
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
