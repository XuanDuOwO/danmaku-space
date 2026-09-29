import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../blive/api.dart';
import '../blive/audience.dart';
import '../blive/client.dart';
import '../blive/gift.dart';
import '../blive/normalize.dart';
import '../core/screen_keeper.dart';
import '../core/store.dart';
import '../core/updater.dart' show cleanUpdateApks;

/// 弹幕空间的共享状态中心。
///
/// 四个模块（传送门 / 弹幕空间 / 设置 / 观众礼物）是彼此独立、可来回切换的
/// 平级页面。房间连接、消息流、统计、观众、礼物这些数据必须由它们共同持有，
/// 否则切页就会断流或丢状态。
class RelayController extends ChangeNotifier {
  RelayController();

  // ---------------------------------------------------------------- 对外状态

  BilibiliApi? _api;
  LiveClient? _client;
  StreamSubscription<LiveEvent>? _eventSub;
  StreamSubscription<RoomStats>? _statsSub;
  StreamSubscription<ConnState>? _stateSub;

  /// 当前房间的实时弹幕（受上限裁剪，只保留最近 [_maxRows] 条）。
  final List<LiveEvent> messages = [];

  /// 被隐藏的事件类型（筛选开关关闭的那些）。
  final Set<EventKind> hidden = {};

  RoomStats stats = RoomStats();
  ConnState state = ConnState.idle;
  RoomInfo? info;

  /// 当前直播间可用的表情表（token → 图片 URL）。
  Map<String, String> roomEmoji = const {};

  List<FavRoom> favs = [];
  List<RecentRoom> recent = [];

  int roomId = 0;
  String? error;

  /// 登录用户昵称（弹幕列表里用于判断是否本人，仅展示用）。
  String loginName = '';

  /// 进场滚动提示：固定显示一条，多人进场时随时间轮换。
  final List<String> enterQueue = [];
  String enterDisplay = '';
  int _enterRot = 0;
  Timer? _enterTimer;

  /// 弹幕空间全屏模式：隐藏页面标题与底部导航，只留直播间信息条和弹幕。
  /// 同时切沉浸式（收起刘海状态栏/手势条，下拉可临时唤出），返回键退出。
  bool danmakuFullscreen = false;

  void setDanmakuFullscreen(bool v) {
    if (danmakuFullscreen == v) return;
    danmakuFullscreen = v;
    // 全屏：状态栏/导航条收起（sticky，滑一下会临时出现后自动隐藏）
    SystemChrome.setEnabledSystemUIMode(
      v ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    notifyListeners();
  }

  // ------------------------------------------------------------ 亮屏保活

  /// 亮屏保活：开启后屏幕不会自动熄灭，适合把手机当弹幕屏挂机。
  /// 由弹幕空间页的开关控制；退出该页/退出应用时自动关闭。
  bool keepScreenOn = false;

  /// 切换亮屏保活。返回是否真的生效（非 Android 平台会失败）。
  Future<bool> setKeepScreenOn(bool v) async {
    final ok = await ScreenKeeper.setEnabled(v);
    keepScreenOn = ok;
    notifyListeners();
    return ok;
  }

  // ------------------------------------------------------------ 实时观众

  /// 直播间**当前在线人数**（B站客户端顶部那个数字）。
  int audienceOnline = 0;

  /// 高能榜观众（按贡献值排序，每条带头像）。
  ///
  /// 注意：榜单只收录「有贡献值」的观众（投喂 / 点赞 / 发弹幕），
  /// 所以这里的条数通常**少于** [audienceOnline]，两者要分开表述。
  List<AudienceMember> audienceMembers = const [];

  /// 高能榜是否还有下一页。
  bool audienceHasMore = false;

  /// 服务端下发的榜单元信息，如「投喂、点赞、发弹幕均可上榜」。
  String audienceTips = '';

  /// 观众数据是否正在刷新（首次加载 / 翻页）。
  bool audienceLoading = false;

  /// 最近一次观众接口失败的原因；成功后清空。
  String? audienceError;

  /// 观众刷新周期：在线人数变化比弹幕慢，30 秒足够且省流量。
  static const Duration audienceInterval = Duration(seconds: 30);

  Timer? _audienceTimer;
  bool _audienceInFlight = false;

  /// 拉取一页观众数据。
  ///
  /// [page] > 1 时是「加载更多」，结果**追加**到现有列表；
  /// [reset] 为 true 或 page == 1 时整体替换。
  Future<void> loadAudience({int page = 1, bool append = false}) async {
    final api = _api;
    final id = roomId;
    if (api == null || id <= 0 || _audienceInFlight) return;
    _audienceInFlight = true;
    audienceLoading = true;
    if (!append) audienceError = null;
    notifyListeners();
    try {
      final res = await api.getOnlineAudience(id, page: page);
      // 期间可能已经切了房间，丢弃过期结果。
      if (id != roomId) return;
      audienceOnline = res.online;
      audienceTips = res.tips;
      audienceHasMore = res.hasMore;
      if (append) {
        final seen = {for (final m in audienceMembers) m.uid};
        audienceMembers = [
          ...audienceMembers,
          ...res.members.where((m) => seen.add(m.uid)),
        ];
      } else {
        audienceMembers = res.members;
      }
      audienceError = null;
    } catch (e) {
      if (id == roomId) audienceError = '$e';
    } finally {
      _audienceInFlight = false;
      audienceLoading = false;
      if (id == roomId) notifyListeners();
    }
  }

  /// 在高能榜里继续往后翻一页。
  Future<void> loadMoreAudience() async {
    if (!audienceHasMore || audienceLoading) return;
    final next = (audienceMembers.length ~/ audiencePageSize) + 1;
    await loadAudience(page: next, append: true);
  }

  void _startAudiencePolling() {
    _audienceTimer?.cancel();
    _audienceTimer = Timer.periodic(audienceInterval, (_) {
      // 只在弹幕空间页可见时才轮询，避免后台空转。
      if (audienceAutoRefresh) unawaited(loadAudience());
    });
  }

  void _stopAudiencePolling() {
    _audienceTimer?.cancel();
    _audienceTimer = null;
  }

  /// 是否允许后台 / 非当前页时继续刷新在线人数。
  /// 由弹幕空间页在可见时打开、切走时关闭。
  bool audienceAutoRefresh = true;

  /// 点击在线人数刷新（也用于下拉重试）。
  Future<void> refreshAudience() => loadAudience();

  static const int _maxRows = 300;
  static const int _enterKeep = 12;

  // ---------------------------------------------------------------- 启动引导

  Future<void> boot() async {
    final cookie = await Store.loadCookie();
    favs = await Store.loadFavorites();
    recent = await Store.loadRecent();
    // 兜底清理：上次会话残留的更新安装包（延迟清理没跑完时补刀）
    unawaited(cleanUpdateApks());
    // 弹幕持久化已移除：把老版本遗留的 dlog_* 数据清掉，把存储还给系统。
    unawaited(Store.purgeLegacyLogs());

    _api = BilibiliApi(cookie: cookie);
    if (cookie.isNotEmpty) {
      try {
        await _api!.ensureIdentity();
        final p = await _api!.getProfile();
        if (p.isLogin) loginName = p.name;
      } catch (_) {
        // 登录态失效则按游客继续（进入 App 前的闸门已经拦过一次）
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 连接

  Future<void> connect(int id) async {
    if (id <= 0) {
      error = '请输入合法的直播间号';
      notifyListeners();
      return;
    }
    await _teardown();
    messages.clear();
    stats = RoomStats();
    error = null;
    info = null;
    roomEmoji = const {};
    roomId = id;
    enterQueue.clear();
    enterDisplay = '';
    _enterTimer?.cancel();
    // 换房间：旧房间的观众数据必须先清掉，否则新房间会先显示上一个房间的人数。
    audienceOnline = 0;
    audienceMembers = const [];
    audienceHasMore = false;
    audienceTips = '';
    audienceError = null;
    // 礼物统计同理：本场金额只统计当前这次连接。
    _gifts.clear();
    giftSummary = GiftSummary.empty;
    notifyListeners();
    await Store.saveRoomId(id);
    recent = await Store.touchRecent(id);
    notifyListeners();

    final api = _api ?? BilibiliApi();
    _api = api;

    // 观众数据：立刻拉一次，之后按周期轮询（与弹幕连接相互独立，
    // 即使弹幕 WebSocket 还在重连，在线人数也能显示）。
    unawaited(loadAudience());
    _startAudiencePolling();

    // 礼物价格表：弹幕报文不带价格，必须靠面板接口换算金额。
    // 面板很大（实测 1.5MB），所以每个房间只拉一次并缓存。
    unawaited(api.fetchGiftPanel(id).then((t) {
      debugPrint('[gift] room=$id 礼物价格表 ${t.length} 项');
      if (roomId == id && !t.isEmpty) {
        giftTable = t;
        notifyListeners();
      }
    }).catchError((Object e) {
      debugPrint('[gift] room=$id 礼物面板拉取失败: $e');
    }));

    // 房间表情表：与弹幕自带的 emots 互补，覆盖直播通用/UP主/灯牌横幅表情。
    unawaited(api.getEmoticons(id).then((m) {
      debugPrint('[emoji] room=$id 房间表情表加载 ${m.length} 项');
      if (roomId == id && m.isNotEmpty) {
        roomEmoji = m;
        notifyListeners();
        unawaited(Store.saveEmojiTable(id, m));
      }
    }).catchError((Object e) {
      debugPrint('[emoji] room=$id 房间表情表拉取失败: $e');
    }));

    final client = LiveClient(roomId: id, api: api);
    _client = client;

    _eventSub = client.events.listen((ev) {
      // 进场消息只进滚动提示，不进弹幕列表，避免刷屏。
      if (ev.kind == EventKind.enter) {
        final name = ev.user.name.isNotEmpty ? ev.user.name : '有人';
        _pushEnter('$name ${ev.text}');
        return;
      }
      // 礼物先计价再入列：extra 里已由 normalize 带上 gift_id / count，
      // 价格查 giftTable（面板接口下发）。
      if (ev.kind == EventKind.gift) _recordGift(ev);
      messages.add(ev);
      if (messages.length > _maxRows) {
        messages.removeRange(0, messages.length - _maxRows);
      }
      notifyListeners();
    });

    _statsSub = client.statsStream.listen((s) {
      stats = s;
      notifyListeners();
    });

    _stateSub = client.stateStream.listen((s) {
      state = s;
      if (s == ConnState.connected) {
        info = client.info;
        _syncFavName();
        unawaited(_touchRecentWithInfo());
        // 连接建立：拉起前台服务，切后台不被系统杀掉
        _startKeepAlive();
      }
      if (s == ConnState.idle || s == ConnState.error) {
        // 连接断开/异常：先撤下保活，重连成功会再次拉起
        _stopKeepAlive();
      }
      if (s == ConnState.error && client.lastError.isNotEmpty) {
        error = client.lastError;
      }
      notifyListeners();
    });

    unawaited(client.start().catchError((Object e) {
      error = '$e';
      notifyListeners();
    }));
  }

  /// 断开当前连接（保留 roomId，便于再次连接）。
  Future<void> disconnect() async {
    await _teardown();
    state = ConnState.idle;
    notifyListeners();
  }

  /// 重连当前房间，重新拉取房间信息与弹幕流。
  void refresh() {
    if (roomId <= 0) return;
    connect(roomId);
  }

  Future<void> _teardown() async {
    await _eventSub?.cancel();
    await _statsSub?.cancel();
    await _stateSub?.cancel();
    _eventSub = null;
    _statsSub = null;
    _stateSub = null;
    _client?.stop();
    _client = null;
    _stopKeepAlive();
    _stopAudiencePolling();
  }

  // ------------------------------------------------------- 前台保活服务

  static const _keepAliveChannel =
      MethodChannel('cn.local.bili_live_relay/open_url');

  /// 拉起前台服务：把进程提到前台优先级，切后台/锁屏时弹幕连接不被杀。
  void _startKeepAlive() {
    _keepAliveChannel
        .invokeMethod('startKeepAlive', {'room': '$roomId'})
        .catchError((_) {});
  }

  void _stopKeepAlive() {
    _keepAliveChannel.invokeMethod('stopKeepAlive').catchError((_) {});
  }

  void _pushEnter(String text) {
    if (text.isEmpty) return;
    enterQueue.add(text);
    if (enterQueue.length > _enterKeep) enterQueue.removeAt(0);
    _enterRot = enterQueue.length - 1;
    enterDisplay = text;
    _enterTimer?.cancel();
    if (enterQueue.length > 1) {
      _enterTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
        _enterRot = (_enterRot + 1) % enterQueue.length;
        enterDisplay = enterQueue[_enterRot];
        notifyListeners();
      });
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 筛选

  bool isVisible(LiveEvent e) => !hidden.contains(e.kind);

  List<LiveEvent> get visibleMessages =>
      messages.where((e) => !hidden.contains(e.kind)).toList();

  void toggleHidden(EventKind k) {
    if (hidden.contains(k)) {
      hidden.remove(k);
    } else {
      hidden.add(k);
    }
    notifyListeners();
  }

  void setHidden(Set<EventKind> v) {
    hidden
      ..clear()
      ..addAll(v);
    notifyListeners();
  }

  // ------------------------------------------------------------------ 收藏

  List<FavRoom> favsOf(String type) =>
      favs.where((f) => f.type == type).toList();

  bool isFav(String type) =>
      roomId > 0 && favs.any((f) => f.roomId == roomId && f.type == type);

  static String typeName(String type) => type == 'tech' ? '技播' : '爱播';

  /// 收藏 / 取消收藏当前房间。返回给用户看的提示语。
  Future<String> toggleFavoriteOf(String type) async {
    if (roomId <= 0) return '请先连接一个直播间';
    final list = List<FavRoom>.from(favs);
    final idx = list.indexWhere((f) => f.roomId == roomId && f.type == type);
    final String msg;
    if (idx >= 0) {
      list.removeAt(idx);
      msg = '已从${typeName(type)}移除 $roomId';
    } else {
      list.add(FavRoom(
        roomId: roomId,
        name: info?.anchorName ?? '',
        face: info?.anchorFace ?? '',
        type: type,
      ));
      final n = (info?.anchorName ?? '').isNotEmpty ? '${info!.anchorName} ' : '';
      msg = '已加入${typeName(type)}：$n$roomId';
    }
    await Store.saveFavorites(list);
    favs = list;
    notifyListeners();
    return msg;
  }

  Future<void> removeFav(FavRoom f) async {
    final list = List<FavRoom>.from(favs)
      ..removeWhere((e) => e.roomId == f.roomId && e.type == f.type);
    await Store.saveFavorites(list);
    favs = list;
    notifyListeners();
  }

  /// 收藏页改完后重新读一次。
  Future<void> reloadFavs() async {
    favs = await Store.loadFavorites();
    notifyListeners();
  }

  /// 清空「最近观看」。
  Future<void> clearRecent() async {
    recent = const [];
    await Store.clearRecent();
    notifyListeners();
  }

  /// 连接成功后补全收藏里的主播名与头像（首存时可能还拿不到）。
  Future<void> _syncFavName() async {
    final id = roomId;
    final name = info?.anchorName ?? '';
    final face = info?.anchorFace ?? '';
    if (id <= 0 || (name.isEmpty && face.isEmpty)) return;
    final idx = favs.indexWhere((f) => f.roomId == id);
    if (idx < 0) return;
    final cur = favs[idx];
    if (cur.name == name && cur.face == face) return;
    final list = List<FavRoom>.from(favs);
    list[idx] = FavRoom(
      roomId: id,
      name: name.isNotEmpty ? name : cur.name,
      face: face.isNotEmpty ? face : cur.face,
      type: cur.type,
    );
    await Store.saveFavorites(list);
    favs = list;
    notifyListeners();
  }

  Future<void> _touchRecentWithInfo() async {
    final id = roomId;
    if (id <= 0) return;
    recent = await Store.touchRecent(
      id,
      name: info?.anchorName ?? '',
      face: info?.anchorFace ?? '',
    );
    notifyListeners();
  }

  // -------------------------------------------------------------- 礼物统计

  /// 礼物价格表（gift_id → 单价）。进房间时拉一次，缓存复用。
  GiftTable giftTable = GiftTable.empty;

  /// 本场礼物累计（连击按增量累加，口径见 [GiftAccumulator]）。
  final GiftAccumulator _gifts = GiftAccumulator();

  /// 当前礼物汇总快照。每次收到礼物后重算并缓存，避免 build 里反复排序。
  GiftSummary giftSummary = GiftSummary.empty;

  /// 收到一条礼物事件时计价累加。
  ///
  /// 价格来源有优先级（实测 37/37 条两者一致，互为备份）：
  ///   1. 礼物面板按 gift_id 查 —— 权威；
  ///   2. 面板还没加载完 / 是新礼物时，退回报文自带的 price
  ///      （`SEND_GIFT_V2` 的 `gift[5]`，或明文的 `data.price`）。
  ///
  /// 这样即使面板请求失败（1.5 MB，弱网下确实会失败），金额也不会全变 0。
  void _recordGift(LiveEvent ev) {
    final name = '${ev.extra['gift_name'] ?? ''}'.trim();
    if (name.isEmpty) return;
    final num = (ev.extra['count'] as int?) ?? 1;
    final id = (ev.extra['gift_id'] as int?) ?? 0;
    final coin = '${ev.extra['coin_type'] ?? ''}';
    final payloadPrice = (ev.extra['price'] as int?) ?? 0;

    var info = giftTable.lookup(id: id, name: name);
    if (info == null && payloadPrice > 0) {
      info = GiftInfo(
        id: id,
        name: name,
        price: payloadPrice,
        coinType: coin.isEmpty ? 'gold' : coin,
      );
    }
    _gifts.add(name: name, num: num, info: info);
    giftSummary = _gifts.snapshot();
  }

  /// 清空本场礼物统计（换房间 / 手动清零时用）。
  void clearGiftSummary() {
    _gifts.clear();
    giftSummary = GiftSummary.empty;
    notifyListeners();
  }

  @override
  void dispose() {
    _enterTimer?.cancel();
    _stopAudiencePolling();
    // 亮屏保活是进程级窗口标志：dispose 时必须撤掉，否则退出应用后
    // 下一个用这个 Activity 的界面也会一直不熄屏。
    if (keepScreenOn) unawaited(ScreenKeeper.release());
    // 保险：退出应用壳时恢复系统 UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_teardown());
    _api?.dispose();
    super.dispose();
  }
}
