import 'dart:convert';

import 'pb.dart';

/// 把 B站原始 cmd 报文归一化成统一的事件结构

enum EventKind { danmaku, gift, enter, guard, superchat, stats, live, system }

String kindName(EventKind k) => switch (k) {
      EventKind.danmaku => 'danmaku',
      EventKind.gift => 'gift',
      EventKind.enter => 'enter',
      EventKind.guard => 'guard',
      EventKind.superchat => 'superchat',
      EventKind.stats => 'stats',
      EventKind.live => 'live',
      EventKind.system => 'system',
    };

class LiveUser {
  final int uid;
  final String name;
  final String face;
  final int level;
  final String? medalName;
  final int medalLevel;
  /// 房管 / 大会员 / 年度大会员，仅 DANMU_MSG 可拿到，其余类型保持 false
  final bool admin;
  final bool vip;
  final bool svip;

  const LiveUser({
    this.uid = 0,
    this.name = '匿名',
    this.face = '',
    this.level = 0,
    this.medalName,
    this.medalLevel = 0,
    this.admin = false,
    this.vip = false,
    this.svip = false,
  });

  bool get hasMedal => medalName != null && medalName!.isNotEmpty;
}

class LiveEvent {
  final EventKind kind;
  final String cmd;
  final int ts;
  final LiveUser user;
  final String text;
  final Map<String, dynamic> extra;
  /// 弹幕内的表情包映射：文本 token（如 "[doge]"）→ 图片 URL。
  final Map<String, String>? emoticons;

  const LiveEvent({
    required this.kind,
    required this.cmd,
    required this.ts,
    required this.user,
    required this.text,
    this.extra = const {},
    this.emoticons,
  });
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// 解析本条弹幕里的表情包，返回 token→url 映射。
///
/// 直播间实测（8385390，DANMU_MSG）：
///   - info[0][13] / info[0][14] 恒为字符串 "{}"，**没有 URL**（早期误以为是这里）。
///   - 真正的表情数据在 **info[0][15]['extra']**，它是一段 JSON **字符串**，
///     其中有 emots 字段，形如：
///         "emots": {
///            "[花]": {"emoji":"[花]","url":"http://i0.hdslb.com/bfs/live/xxxx.png",
///                     "emoticon_unique":"emoji_209","width":20,"height":20,"count":1}
///         }
///     普通纯文字弹幕该处为 "emots":null。
///
/// 直接从下发报文取 url，不依赖任何第三方表情表，token 与图 100% 对齐。
Map<String, String>? _parseEmoticons(List<dynamic> info) {
  final f15 = digging(info, [0, 15], fallback: null);
  if (f15 is! Map) return null;
  final extra = f15['extra'];
  if (extra is! String || extra.isEmpty) return null;

  dynamic parsed;
  try {
    parsed = jsonDecode(extra);
  } catch (_) {
    return null;
  }
  if (parsed is! Map) return null;
  final emots = parsed['emots'];
  if (emots is! Map || emots.isEmpty) return null;

  final map = <String, String>{};
  emots.forEach((k, v) {
    if (v is! Map) return;
    var url = v['url'];
    if (url is! String || url.isEmpty) return;
    if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }
    // emoji 字段形如 "[花]"（带中括号），与文本中的占位符一致；
    // 缺失时退回 map 的 key。
    var token = v['emoji'];
    if (token is! String || token.isEmpty) token = k is String ? k : null;
    if (token is! String || token.isEmpty) return;
    map[token] = url;
    // 再去括号存一份，兼容不带中括号的占位符。
    if (token.startsWith('[') && token.endsWith(']') && token.length > 2) {
      map[token.substring(1, token.length - 1)] = url;
    }
  });
  return map.isEmpty ? null : map;
}

/// 逐层取值，任一层缺失返回 [fallback]。
dynamic digging(dynamic obj, List<int> path, {dynamic fallback}) {
  dynamic cur = obj;
  for (final key in path) {
    if (cur is List) {
      if (key < 0 || key >= cur.length) return fallback;
      cur = cur[key];
    } else if (cur is Map) {
      cur = cur[key];
    } else {
      return fallback;
    }
    if (cur == null) return fallback;
  }
  return cur;
}

LiveEvent _danmaku(Map<String, dynamic> j) {
  final info = (j['info'] as List<dynamic>?) ?? const <dynamic>[];
  final medalLevel = digging(info, [3, 0], fallback: 0) as int? ?? 0;
  final medalName = digging(info, [3, 1], fallback: '') as String? ?? '';
  // info[2] = [uid, 昵称, 房管, 大会员, 年度大会员, ...]
  final svip = (digging(info, [2, 4], fallback: 0) as int? ?? 0) != 0;
  final vip = ((digging(info, [2, 3], fallback: 0) as int? ?? 0) != 0) || svip;
  final admin = (digging(info, [2, 2], fallback: 0) as int? ?? 0) != 0;
  return LiveEvent(
    kind: EventKind.danmaku,
    cmd: 'DANMU_MSG',
    ts: digging(info, [0, 4], fallback: _nowMs()) as int? ?? _nowMs(),
    user: LiveUser(
      uid: digging(info, [2, 0], fallback: 0) as int? ?? 0,
      name: digging(info, [2, 1], fallback: '匿名') as String? ?? '匿名',
      level: digging(info, [4, 0], fallback: 0) as int? ?? 0,
      medalName: medalName,
      medalLevel: medalLevel,
      admin: admin,
      vip: vip,
      svip: svip,
    ),
    text: digging(info, [1], fallback: '') as String? ?? '',
    emoticons: _parseEmoticons(info),
    extra: {
      'fontsize': digging(info, [0, 2], fallback: 25),
      'color': digging(info, [0, 3], fallback: 16777215),
    },
  );
}

/// 礼物：新版 SEND_GIFT_V2 已改 protobuf，旧版 SEND_GIFT 仍是明文。
///
/// 关于**价格**：实测（2026-09）弹幕流里的礼物报文**不可靠地携带价格** ——
/// 新版 protobuf 的 `gift[5]` 偶尔有值、偶尔缺失，旧版明文的 `data.price`
/// 也只是 B站自己给的两个不同口径之一。所以计价一律以礼物面板接口
/// （`roomGiftConfig`）为权威来源，这里只负责把 **gift_id / 名称 / 数量**
/// 带出去，交给 [GiftTable] 换算。
///
/// 关于**数量**：实测连击时 `gift[3]`（num）是**本批增量**而不是累计值
/// ——同一个 combo_id 连续出现 num=1,1,1,1 时总数量就是 4。
/// 因此这里原样透出 num，由累加器直接相加即可，不需要去重。
LiveEvent _gift(Map<String, dynamic> j) {
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  final cmd = (j['cmd'] as String?) ?? 'SEND_GIFT';
  final pbText = d['pb'] as String?;

  if (pbText != null && pbText.isNotEmpty) {
    Map<int, dynamic> pb = const {};
    try {
      pb = pbDecode(base64Decode(pbText));
    } catch (_) {}
    final gift = pbGet(pb, [10], defaultValue: const {});
    final giftMap = gift is Map ? gift as Map<int, dynamic> : const <int, dynamic>{};
    final name = pbGet(pb, [2], defaultValue: '匿名') as String? ?? '匿名';
    final giftName = (giftMap[2] as String?) ?? '礼物';
    final count = (giftMap[3] as int?) ?? 1;
    final action = (giftMap[18] as String?) ?? '投喂';
    final sec = (giftMap[10] as int?) ?? 0;
    return LiveEvent(
      kind: EventKind.gift,
      cmd: cmd,
      ts: sec > 0 ? sec * 1000 : _nowMs(),
      user: LiveUser(
        // 实测 uid 在 pb[1]，而不是早先以为的 pb[34][1]（那里是别的 id）。
        uid: (pbGet(pb, [1], defaultValue: 0) as int?) ??
            (pbGet(pb, [34, 1], defaultValue: 0) as int?) ??
            0,
        name: name,
        face: pbGet(pb, [3], defaultValue: '') as String? ?? '',
      ),
      text: '$name $action $giftName x$count',
      extra: {
        'gift_name': giftName,
        'count': count,
        'price': (giftMap[5] as int?) ?? 0,
        'coin_type': (giftMap[8] as String?) ?? '',
        'gift_id': (giftMap[1] as int?) ?? 0,
      },
    );
  }
  final uname = (d['uname'] as String?) ?? '';
  final giftName = (d['giftName'] ?? d['gift_name'] ?? '礼物') as String? ?? '礼物';
  final count = (d['num'] as int?) ?? 1;
  return LiveEvent(
    kind: EventKind.gift,
    cmd: cmd,
    ts: _nowMs(),
    user: LiveUser(uid: (d['uid'] as int?) ?? 0, name: uname,
        face: (d['face'] as String?) ?? ''),
    text: '$uname ${d['action'] ?? '投喂'} $giftName x$count',
    extra: {
      'gift_name': giftName,
      'count': count,
      'price': (d['price'] as int?) ?? 0,
      'coin_type': (d['coin_type'] as String?) ?? '',
      'gift_id': (d['gift_id'] as int?) ?? (d['giftId'] as int?) ?? 0,
    },
  );
}

/// 进场：新版 INTERACT_WORD_V2 的字段压在 protobuf 里。
LiveEvent _interactV2(Map<String, dynamic> j) {
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  Map<int, dynamic> pb = const {};
  final pbText = d['pb'] as String?;
  if (pbText != null && pbText.isNotEmpty) {
    try {
      pb = pbDecode(base64Decode(pbText));
    } catch (_) {}
  }
  final name = pbGet(pb, [2], defaultValue: null) as String?
      ?? pbGet(pb, [22, 2, 1], defaultValue: '匿名') as String?
      ?? '匿名';
  final uid = pbGet(pb, [1], defaultValue: 0) as int? ?? 0;
  final face = pbGet(pb, [22, 2, 2], defaultValue: '') as String? ?? '';
  final medalLevel = pbGet(pb, [9, 2], defaultValue: 0) as int? ?? 0;
  final medalName = pbGet(pb, [9, 3], defaultValue: '') as String? ?? '';
  final node = pbGet(pb, [23], defaultValue: const {});
  final tail = (node is Map ? (node[2] as String?) : null) ?? '';
  return LiveEvent(
    kind: EventKind.enter,
    cmd: 'INTERACT_WORD_V2',
    ts: _nowMs(),
    user: LiveUser(
      uid: uid, name: name, face: face,
      medalName: medalName, medalLevel: medalLevel,
    ),
    text: tail.isNotEmpty ? tail : '进入了直播间',
    extra: {'msg_type': pbGet(pb, [5], defaultValue: 1)},
  );
}

LiveEvent _interact(Map<String, dynamic> j) {
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  final medal = (d['medal_info'] as Map<String, dynamic>?) ?? const {};
  return LiveEvent(
    kind: EventKind.enter,
    cmd: 'INTERACT_WORD',
    ts: _nowMs(),
    user: LiveUser(
      uid: (d['uid'] as int?) ?? 0,
      name: (d['uname'] as String?) ?? '匿名',
      face: (d['face'] as String?) ?? '',
      medalName: (medal['medal_name'] as String?) ?? '',
      medalLevel: (medal['medal_level'] as int?) ?? 0,
    ),
    text: (d['msg_type'] == 2) ? '关注了主播' : '进入了直播间',
  );
}

LiveEvent _guard(Map<String, dynamic> j) {
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  final ui = (d['user_info'] as Map<String, dynamic>?) ?? const {};
  final name = (d['username'] ?? ui['uname'] ?? '匿名') as String? ?? '匿名';
  final giftName = (d['gift_name'] as String?) ?? '大航海';
  return LiveEvent(
    kind: EventKind.guard,
    cmd: (j['cmd'] as String?) ?? 'GUARD_BUY',
    ts: _nowMs(),
    user: LiveUser(uid: (d['uid'] ?? ui['uid'] ?? 0) as int? ?? 0, name: name),
    text: '$name 开通了 $giftName x${d['num'] ?? 1}',
    extra: {
      'gift_name': giftName,
      'guard_level': (d['guard_level'] as int?) ?? 0,
    },
  );
}

LiveEvent _superchat(Map<String, dynamic> j) {
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  final ui = (d['user_info'] as Map<String, dynamic>?) ?? const {};
  final name = (ui['uname'] as String?) ?? '匿名';
  return LiveEvent(
    kind: EventKind.superchat,
    cmd: 'SUPER_CHAT_MESSAGE',
    ts: _nowMs(),
    user: LiveUser(
      uid: (d['uid'] as int?) ?? 0,
      name: name,
      face: (ui['face'] as String?) ?? '',
    ),
    text: (d['message'] as String?) ?? '',
    extra: {
      'price': (d['price'] as int?) ?? 0,
      'duration': (d['time'] as int?) ?? 60,
      'background': (d['background_bottom_color'] as String?) ?? '',
    },
  );
}

/// 各类指标更新合并成 stats 事件，便于 UI 刷新。
LiveEvent? _stats(Map<String, dynamic> j) {
  final cmd = (j['cmd'] as String?) ?? '';
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  final extra = <String, dynamic>{};
  switch (cmd) {
    case 'WATCHED_CHANGE':
      extra['watched'] = d['num'];
      break;
    case 'ONLINE_RANK_COUNT':
      extra['online'] = d['count'] ?? d['online_count'];
      break;
    case 'LIKE_INFO_V3_UPDATE':
    case 'LIKE_INFO_V3_CLICK':
      extra['likes'] = d['click_count'];
      break;
    case 'ROOM_REAL_TIME_MESSAGE_UPDATE':
      extra['fans'] = d['fans'];
      extra['fans_club'] = d['fans_club'];
      break;
    case 'POPULAR_RANK_CHANGED':
      extra['rank'] = d['rank'];
      break;
    default:
      return null;
  }
  return LiveEvent(
    kind: EventKind.stats,
    cmd: cmd,
    ts: _nowMs(),
    user: const LiveUser(),
    text: '',
    extra: extra,
  );
}

/// 高能进场特效（舰长 / 大航海进场时的横幅）。
///
/// 报文里的 `copy_writing` 是**带占位符的模板**，形如
/// `<%Ra1nFlo...%> 来了` —— 占位符里是观众昵称，而且服务端常常把它
/// **截断**（`...` 就是截断标记）。直接显示会变成
/// 「有人 <%Ra1nFlo...%> 来了」，既难看又没信息量。
///
/// 处理原则：
///   - 占位符被截断 → 名字不可用，整条丢弃（返回 null）。
///     这类进场在 `INTERACT_WORD_V2` 里已经有一条完整可读的记录，
///     丢掉不会漏消息，只会少一次重复刷屏；
///   - 占位符完整 → 去掉占位符，保留两侧的有效文案。
LiveEvent? _entryEffect(Map<String, dynamic> j) {
  final d = (j['data'] as Map<String, dynamic>?) ?? const {};
  final raw = '${d['copy_writing'] ?? d['copy_writing_v2'] ?? ''}';

  // 名字被截断（占位符里有 ... 或 …）→ 整条没有可用信息
  final truncated = RegExp(r'<%[^%]*(?:\.\.\.|…)[^%]*%>').hasMatch(raw);
  if (truncated) return null;

  final cleaned = raw
      .replaceAll(RegExp(r'<%[^%]*%>'), '')
      .replaceAll(RegExp(r'[<>]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return null;

  return LiveEvent(
    kind: EventKind.enter,
    cmd: 'ENTRY_EFFECT',
    ts: _nowMs(),
    user: LiveUser(
      uid: (d['uid'] as int?) ?? 0,
      // 名字只存在于占位符里，这里拿不到可靠的昵称，交给上层用「有人」兜底。
      name: '',
      face: (d['face'] as String?) ?? '',
    ),
    text: cleaned,
  );
}

/// 各 cmd 的处理器。返回 null 表示「这个包没有可展示的内容」，
/// 上层会直接忽略（例如 ENTRY_EFFECT 去掉占位符后没剩下东西）。
final _handler = <String, LiveEvent? Function(Map<String, dynamic>)>{
  'DANMU_MSG': _danmaku,
  'INTERACT_WORD_V2': _interactV2,
  'INTERACT_WORD': _interact,
  'SEND_GIFT': _gift,
  'SEND_GIFT_V2': _gift,
  'COMBO_SEND': _gift,
  'GUARD_BUY': _guard,
  'USER_TOAST_MSG': _guard,
  'SUPER_CHAT_MESSAGE': _superchat,
  'ENTRY_EFFECT': _entryEffect,
};

const _statsCmds = {
  'WATCHED_CHANGE',
  'ONLINE_RANK_COUNT',
  'LIKE_INFO_V3_UPDATE',
  'LIKE_INFO_V3_CLICK',
  'ROOM_REAL_TIME_MESSAGE_UPDATE',
  'POPULAR_RANK_CHANGED',
};

/// 归一化入口，无法识别的消息类型（以及处理器认为无需展示的）返回 null。
LiveEvent? normalize(Map<String, dynamic> payload) {
  final cmd = (payload['cmd'] as String?) ?? '';
  final fn = _handler[cmd];
  if (fn != null) {
    try {
      return fn(payload);
    } catch (_) {
      return null;
    }
  }
  if (cmd == 'LIVE' || cmd == 'PREPARING') {
    return LiveEvent(
      kind: EventKind.live,
      cmd: cmd,
      ts: _nowMs(),
      user: const LiveUser(name: ''), // 空名，避免渲染成「匿名：开播了」
      text: cmd == 'LIVE' ? '开播了' : '下播了',
    );
  }
  if (_statsCmds.contains(cmd)) return _stats(payload);
  return null;
}
