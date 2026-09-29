/// 礼物价格表与礼物价值统计。
///
/// 为什么需要这张表：**弹幕流里的礼物报文不带价格**。实测 `SEND_GIFT` 的
/// `data` 里只有 `giftName` / `num` / `price`（旧版字段，新版 protobuf 包里
/// 干脆没有），而新版 `SEND_GIFT_V2` 的价格字段语义不可靠。
/// 唯一权威来源是礼物面板接口 `roomGiftConfig`，它给出每个礼物的单价。
///
/// 计价单位：B站用「金瓜子」计价，**1000 金瓜子 = 1 元人民币**。
/// 例如 `爱心小熊` price=52000 → 52 元。面板里还有 `coin_type='silver'`
/// 的免费礼物（辣条、小心心等），价格恒为 0，不计入金额统计。
library;

/// 金瓜子 → 人民币的换算基数。
const int goldBeansPerYuan = 1000;

/// 一个礼物的面板信息。
class GiftInfo {
  final int id;
  final String name;

  /// 单价（金瓜子）。免费礼物为 0。
  final int price;

  /// 'gold' = 金瓜子（付费），'silver' = 银瓜子（免费）。
  final String coinType;

  const GiftInfo({
    required this.id,
    required this.name,
    this.price = 0,
    this.coinType = 'gold',
  });

  /// 是否是需要花钱的礼物。
  bool get isPaid => coinType == 'gold' && price > 0;

  /// 单价（元）。
  double get yuan => price / goldBeansPerYuan;

  @override
  String toString() => 'GiftInfo($id $name $price金瓜子 $coinType)';
}

/// id → [GiftInfo] 的价格表。
///
/// 同一个礼物名在面板里可能对应多个 id（B站会按房间/活动发不同的 id），
/// 所以**按名字**也要能查到；[byName] 就是为此准备的兜底索引。
class GiftTable {
  final Map<int, GiftInfo> byId;
  final Map<String, GiftInfo> byName;

  const GiftTable._(this.byId, this.byName);

  static const GiftTable empty = GiftTable._({}, {});

  bool get isEmpty => byId.isEmpty && byName.isEmpty;
  int get length => byId.length;

  /// 先按 id 查，id 查不到（报文里只有名字）再按名字查。
  GiftInfo? lookup({int id = 0, String name = ''}) {
    if (id > 0) {
      final hit = byId[id];
      if (hit != null) return hit;
    }
    if (name.isNotEmpty) {
      final hit = byName[name];
      if (hit != null) return hit;
      // B站偶尔在名字后面加「×N」或空格，做一次宽松匹配
      final trimmed = name.trim();
      final loose = byName[trimmed];
      if (loose != null) return loose;
    }
    return null;
  }

  /// 解析礼物面板响应。
  ///
  /// 面板结构在不同版本里出现过两种：`data.global_gift.list` 与 `data.list`，
  /// 两个都取，按 id 去重（后者是当前房间可用的子集，价格与前者一致）。
  static GiftTable parse(Object? raw) {
    final root = raw is Map ? raw : const {};
    final data = root['data'] is Map ? root['data'] as Map : const {};

    final items = <Object?>[];
    final global = data['global_gift'];
    if (global is Map && global['list'] is List) {
      items.addAll((global['list'] as List).cast<Object?>());
    }
    if (data['list'] is List) {
      items.addAll((data['list'] as List).cast<Object?>());
    }

    final byId = <int, GiftInfo>{};
    final byName = <String, GiftInfo>{};
    for (final it in items) {
      if (it is! Map) continue;
      final id = _asInt(it['id']);
      final name = _asString(it['name']);
      if (id <= 0 || name.isEmpty) continue;
      final info = GiftInfo(
        id: id,
        name: name,
        price: _asInt(it['price']),
        coinType: _asString(it['coin_type']).isEmpty
            ? 'gold'
            : _asString(it['coin_type']),
      );
      byId.putIfAbsent(id, () => info);
      // 同名只留付费的那条：面板里免费与付费会重名（如「人气票」）。
      final exist = byName[name];
      if (exist == null || (!exist.isPaid && info.isPaid)) {
        byName[name] = info;
      }
    }
    return GiftTable._(byId, byName);
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _asString(Object? v) => v is String ? v.trim() : '';

// ------------------------------------------------------------ 本场统计

/// 一个礼物（按名字聚合）在本场的累计情况。
class GiftTally {
  final String name;
  final int count;

  /// 单次投喂的最大数量（用于展示「×N」）。
  final int maxBatch;

  /// 累计价值（金瓜子）。
  final int gold;

  const GiftTally({
    required this.name,
    required this.count,
    required this.gold,
    this.maxBatch = 1,
  });

  bool get paid => gold > 0;
  double get yuan => gold / goldBeansPerYuan;

  /// 单价（金瓜子）；面板查不到时为 0。
  int get unitPrice => count > 0 ? gold ~/ count : 0;

  Map<String, dynamic> toJson() => {
        'name': name,
        'count': count,
        'gold': gold,
        'maxBatch': maxBatch,
      };

  factory GiftTally.fromJson(Map<String, dynamic> j) => GiftTally(
        name: _asString(j['name']),
        count: _asInt(j['count']),
        gold: _asInt(j['gold']),
        maxBatch: _asInt(j['maxBatch']) == 0 ? 1 : _asInt(j['maxBatch']),
      );
}

/// 本场礼物的汇总：总金额、付费礼物件数、各礼物明细。
///
/// **口径说明**：这里统计的是「本次连接期间收到的礼物」，
/// 不是直播间开播以来的全部礼物（B站不对外提供后者的接口）。
/// 断线重连会清空重算，界面上要写清楚。
class GiftSummary {
  /// 完整明细（含免费礼物），按价值降序、同价值按数量降序。
  final List<GiftTally> items;

  /// 付费礼物总件数（不含免费礼物）。
  final int paidCount;

  /// 付费礼物总价值（金瓜子）。
  final int totalGold;

  /// 免费礼物总件数（辣条、小心心这类银瓜子礼物）。
  final int freeCount;

  /// 有礼物因为不在价格表里而无法计价时的条数。
  final int unknownCount;

  const GiftSummary({
    this.items = const [],
    this.paidCount = 0,
    this.totalGold = 0,
    this.freeCount = 0,
    this.unknownCount = 0,
  });

  static const GiftSummary empty = GiftSummary();

  double get totalYuan => totalGold / goldBeansPerYuan;
  bool get isEmpty => items.isEmpty;

  /// 只保留付费礼物（界面上「只看付费」开关用）。
  List<GiftTally> get paidItems =>
      items.where((e) => e.paid).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'items': items.map((e) => e.toJson()).toList(),
        'paidCount': paidCount,
        'totalGold': totalGold,
        'freeCount': freeCount,
        'unknownCount': unknownCount,
      };

  factory GiftSummary.fromJson(Map<String, dynamic> j) => GiftSummary(
        items: (j['items'] is List)
            ? (j['items'] as List)
                .whereType<Map>()
                .map((e) => GiftTally.fromJson(e.cast<String, dynamic>()))
                .toList()
            : const [],
        paidCount: _asInt(j['paidCount']),
        totalGold: _asInt(j['totalGold']),
        freeCount: _asInt(j['freeCount']),
        unknownCount: _asInt(j['unknownCount']),
      );
}

/// 累加器：把一条条礼物事件喂进来，随时能读出汇总。
///
/// 设计成可变对象而不是「每来一条就全量重算」：礼物可能很密集，
/// 重算整个 map 的排序在弹幕高峰期是纯浪费。
class GiftAccumulator {
  final Map<String, GiftTally> _byName = {};
  int paidCount = 0;
  int totalGold = 0;
  int freeCount = 0;
  int unknownCount = 0;

  /// 记一笔礼物。[num] 是本次投喂数量。
  ///
  /// [info] 为 null 表示价格表里没有这个礼物（新礼物 / 活动礼物），
  /// 此时仍计入数量，但金额记 0，并累加 [unknownCount] 让界面能提示。
  void add({required String name, required int num, GiftInfo? info}) {
    if (name.isEmpty || num <= 0) return;
    final count = _byName;
    final prev = count[name];
    final unit = info?.isPaid == true ? info!.price : 0;
    final gold = unit * num;
    if (info == null) {
      unknownCount++;
    } else if (info.isPaid) {
      paidCount += num;
      totalGold += gold;
    } else {
      freeCount += num;
    }
    count[name] = GiftTally(
      name: name,
      count: (prev?.count ?? 0) + num,
      gold: (prev?.gold ?? 0) + gold,
      maxBatch: num > (prev?.maxBatch ?? 0) ? num : (prev?.maxBatch ?? 1),
    );
  }

  /// 读出当前汇总。排序放在这里做，读取频率远低于写入。
  GiftSummary snapshot() {
    final list = _byName.values.toList()
      ..sort((a, b) {
        final byGold = b.gold.compareTo(a.gold);
        if (byGold != 0) return byGold;
        return b.count.compareTo(a.count);
      });
    return GiftSummary(
      items: list,
      paidCount: paidCount,
      totalGold: totalGold,
      freeCount: freeCount,
      unknownCount: unknownCount,
    );
  }

  void clear() {
    _byName.clear();
    paidCount = 0;
    totalGold = 0;
    freeCount = 0;
    unknownCount = 0;
  }

  double get totalYuan => totalGold / goldBeansPerYuan;
}

/// 金额格式化：把金瓜子换算成「¥1,234.5」或「¥52」。
///
/// 之所以不用 `NumberFormat`：为了一个小工具引入 intl 依赖不划算，
/// 而且这里只需要千分位 + 最多一位小数。
String formatYuan(double yuan) {
  if (yuan <= 0) return '¥0';
  // 小于 1 元保留两位，其余保留一位（避免 ¥0.05 显示成 ¥0.1）
  final text = yuan < 1
      ? yuan.toStringAsFixed(2)
      : (yuan == yuan.roundToDouble()
          ? yuan.toStringAsFixed(0)
          : yuan.toStringAsFixed(1));
  final dot = text.indexOf('.');
  final intPart = dot < 0 ? text : text.substring(0, dot);
  final decPart = dot < 0 ? '' : text.substring(dot);
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '¥$buf$decPart';
}
