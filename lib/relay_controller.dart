import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'blive/api.dart';
import 'blive/client.dart';
import 'blive/normalize.dart';
import 'store.dart';

/// 弹幕空间的共享状态中心。
///
/// 之所以要把状态从「弹幕页」里提出来：现在四个模块（传送门 / 弹幕空间 /
/// 设置 / 弹幕记录）是彼此独立、可来回切换的平级页面，而不是一个主页面带三个
/// 子页面。房间连接、消息流、统计、筛选这些数据必须由它们共同持有，
/// 否则切页就会断流或丢状态。
///
/// 另外它还负责一件事：把收到的每条弹幕按天持久化到本地，
/// 形成**跨主播、跨会话**的「弹幕记录」。
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

  /// 弹幕记录每次追加都自增，弹幕记录页据此判断是否需要重载。
  final ValueNotifier<int> logRevision = ValueNotifier<int>(0);

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

  /// 今日已写入的记录条数（弹幕记录页顶部展示）。
  int todayLogged = 0;

  static const int _maxRows = 300;
  static const int _enterKeep = 12;

  // ---------------------------------------------------------------- 启动引导

  Future<void> boot() async {
    final cookie = await Store.loadCookie();
    favs = await Store.loadFavorites();
    recent = await Store.loadRecent();
    await Store.initLogSeq();
    unawaited(Store.pruneLogs());

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
    notifyListeners();
    await Store.saveRoomId(id);
    recent = await Store.touchRecent(id);
    notifyListeners();

    final api = _api ?? BilibiliApi();
    _api = api;

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
      messages.add(ev);
      if (messages.length > _maxRows) {
        messages.removeRange(0, messages.length - _maxRows);
      }
      _record(ev);
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

  // -------------------------------------------------------------- 弹幕记录

  /// 当前正在累积的那一天（正常情况下就是今天）。
  String _logDay = '';

  /// **尚未落盘**的条目。落盘成功后立即清空——
  /// 这样用户在弹幕记录页删掉的条目不会被下一次 flush 又写回去。
  final List<LogEntry> _pending = [];
  Timer? _flushTimer;

  /// 把一条事件写进弹幕记录（内存先攒着，定时批量落盘）。
  void _record(LiveEvent ev) {
    final now = DateTime.now();
    final day = LogEntry.dayOf(now.millisecondsSinceEpoch);
    if (_logDay != day) {
      // 跨天（含首次）：先把上一天的内容落盘，再开新的一天。
      unawaited(_flush());
      _logDay = day;
      _pending.clear();
      todayLogged = 0;
      unawaited(_loadTodayCount(day));
    }
    _pending.add(LogEntry(
      id: Store.reserveLogId(),
      ts: ev.ts > 0 ? ev.ts : now.millisecondsSinceEpoch,
      roomId: roomId,
      anchor: info?.anchorName ?? '',
      anchorFace: info?.anchorFace ?? '',
      user: ev.user.name,
      text: ev.text,
      kind: ev.kind.name,
      emo: ev.emoticons ?? const {},
    ));
    todayLogged++;
    _flushTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_pending.isNotEmpty) unawaited(_flush());
    });
    // 攒够 40 条也顺手刷一次，避免进程被杀时丢太多。
    if (_pending.length >= 40) unawaited(_flush());
  }

  /// 首次接触某天时，把该天磁盘上已有的条数读进来（本次开始前就存在的）。
  Future<void> _loadTodayCount(String day) async {
    final n = (await Store.loadLogDay(day)).length;
    todayLogged = n + _pending.length;
    notifyListeners();
  }

  Future<void> _flush() async {
    if (_pending.isEmpty || _logDay.isEmpty) return;
    final batch = List<LogEntry>.from(_pending);
    _pending.clear();
    final existing = await Store.loadLogDay(_logDay);
    final seen = <int>{for (final e in existing) e.id};
    final merged = List<LogEntry>.from(existing);
    for (final e in batch) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort((a, b) => a.ts.compareTo(b.ts));
    await Store.saveLogDay(_logDay, merged);
    logRevision.value++;
  }

  /// 弹幕记录页删除条目后调用：把这几条从待写队列里也抹掉，避免复活。
  void dropPending(Set<int> ids) {
    if (ids.isEmpty) return;
    _pending.removeWhere((e) => ids.contains(e.id));
  }

  /// 立刻落盘（切到弹幕记录页、退出登录前调用）。
  Future<void> flushLog() => _flush();

  @override
  void dispose() {
    _enterTimer?.cancel();
    _flushTimer?.cancel();
    // 保险：退出应用壳时恢复系统 UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_flush());
    unawaited(_teardown());
    _api?.dispose();
    logRevision.dispose();
    super.dispose();
  }
}
