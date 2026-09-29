/// 直播间观众数据：在线人数 + 高能榜（带头像的观众列表）。
///
/// 数据源：`xlive/general-interface/v1/rank/getOnlineGoldRank`
///   - `data.onlineNum`       直播间**当前在线人数**（B站客户端顶部显示的就是它）
///   - `data.OnlineRankItem`  高能榜条目：投喂 / 点赞 / 发弹幕都会上榜，
///                            每条带 uid、昵称、头像、贡献值、荣耀等级、粉丝勋章
///
/// 实测（2026-09，房间 22637261）：
///   - 单页 `pageSize` 上限 **50**，传 100 也只回 50；
///   - 榜单只列出「有贡献值」的观众，条数**少于**在线人数
///     （在线 245 人时榜单约 69 条）——界面必须把这两个数字分开表述，
///     不能拿榜单条数当在线人数。
///
/// 该接口不需要登录态，匿名（补一个 buvid3 即可）就能读。
library;

/// 高能榜单页最大条数（服务端硬上限，传更大值无效）。
const int audiencePageSize = 50;

/// 一名观众（高能榜条目）。
class AudienceMember {
  final int uid;
  final String name;

  /// 头像地址，已统一转成 https。
  final String face;

  /// 贡献值（高能榜按它排序）。
  final int score;

  /// 榜内名次，从 1 开始；0 表示服务端没给。
  final int rank;

  /// 0 = 无，1 = 总督，2 = 提督，3 = 舰长。
  final int guardLevel;

  /// 荣耀等级（用户在该直播间的消费等级）。
  final int wealthLevel;

  /// B站对开启隐私保护的用户返回神秘人标记。
  final bool isMystery;

  /// 粉丝勋章名与等级（可能是空串 / 0）。
  final String medalName;
  final int medalLevel;

  const AudienceMember({
    required this.uid,
    this.name = '',
    this.face = '',
    this.score = 0,
    this.rank = 0,
    this.guardLevel = 0,
    this.wealthLevel = 0,
    this.isMystery = false,
    this.medalName = '',
    this.medalLevel = 0,
  });

  bool get hasMedal => medalName.isNotEmpty;

  /// 没有昵称时的显示名（神秘人 / 接口缺字段）。
  String get displayName {
    if (isMystery) return '神秘人';
    if (name.isNotEmpty) return name;
    return '用户$uid';
  }

  /// 舰长等级中文名；非大航海返回空串。
  String get guardLabel => switch (guardLevel) {
        1 => '总督',
        2 => '提督',
        3 => '舰长',
        _ => '',
      };

  @override
  String toString() =>
      'AudienceMember(#$rank $displayName uid=$uid score=$score guard=$guardLevel)';
}

/// 一页观众数据。
class AudienceSnapshot {
  /// 直播间当前在线人数（官方口径，与榜单条数无关）。
  final int online;

  final List<AudienceMember> members;

  /// 请求的是第几页（1 起）。
  final int page;

  /// 是否还有下一页（按「本页拿满了」推断）。
  final bool hasMore;

  /// 服务端下发的提示文案，如「投喂、点赞、发弹幕均可上榜」。
  final String tips;

  const AudienceSnapshot({
    required this.online,
    this.members = const [],
    this.page = 1,
    this.hasMore = false,
    this.tips = '',
  });

  static const AudienceSnapshot empty = AudienceSnapshot(online: 0);
}

// ------------------------------------------------------------------ 解析

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _asString(Object? v) => v is String ? v.trim() : '';

List<Object?>? _asList(Object? v) => v is List ? v.cast<Object?>() : null;

/// B站头像 / 封面大量使用 http://，Android 9+ 默认禁明文，统一转 https。
String _secure(String u) =>
    u.startsWith('http://') ? 'https://${u.substring(7)}' : u;

/// 把一条高能榜条目解析成 [AudienceMember]；uid 非法时返回 null。
AudienceMember? parseAudienceMember(Object? raw) {
  if (raw is! Map) return null;
  final uid = _asInt(raw['uid']);
  if (uid <= 0) return null;
  final medal = raw['medalInfo'] is Map
      ? raw['medalInfo'] as Map
      : (raw['medal_info'] is Map ? raw['medal_info'] as Map : const {});
  return AudienceMember(
    uid: uid,
    name: _asString(raw['name']),
    face: _secure(_asString(raw['face'])),
    score: _asInt(raw['score']),
    rank: _asInt(raw['userRank']),
    guardLevel: _asInt(raw['guard_level']),
    wealthLevel: _asInt(raw['wealth_level']),
    isMystery: raw['is_mystery'] == true,
    medalName: _asString(medal['medalName']),
    medalLevel: _asInt(medal['level']),
  );
}

/// 解析整页响应。
///
/// 字段名在不同版本里出现过 `OnlineRankItem` / `onlineRankItem` / `list`
/// 三种写法，这里都兼容；整包结构异常时退化成只带在线人数的空页，
/// 不让一次接口抖动打断弹幕主链路。
AudienceSnapshot parseAudienceSnapshot(
  Object? raw, {
  int page = 1,
  int pageSize = audiencePageSize,
}) {
  final root = raw is Map ? raw : const {};
  final data = root['data'] is Map ? root['data'] as Map : const {};

  final items = _asList(data['OnlineRankItem']) ??
      _asList(data['onlineRankItem']) ??
      _asList(data['list']) ??
      const <Object?>[];

  final members = <AudienceMember>[];
  final seen = <int>{};
  for (final it in items) {
    final m = parseAudienceMember(it);
    if (m != null && seen.add(m.uid)) members.add(m);
  }

  return AudienceSnapshot(
    online: _asInt(data['onlineNum']),
    members: members,
    page: page,
    hasMore: members.length >= pageSize,
    tips: _asString(data['tips_text']),
  );
}
