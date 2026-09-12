import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'api.dart';
import 'normalize.dart';
import 'protocol.dart';

/// 单直播间弹幕抓取会话：鉴权、心跳保活、解包、归一化、自动重连

const int _heartbeatSeconds = 25; // 服务端 60s 无心跳即断开
const int _idleTimeoutSeconds = 75; // 超过该时间无下行数据判定僵死
const int _popularitySeconds = 30;
const double _maxBackoff = 60;

class RoomStats {
  int danmaku = 0;
  int gift = 0;
  int enter = 0;
  int guard = 0;
  int superchat = 0;
  int likes = 0;
  int popularity = 0;
  int online = 0;
  int watched = 0;
  int fans = 0;
  int fansClub = 0;

  RoomStats copy() => RoomStats()
    ..danmaku = danmaku
    ..gift = gift
    ..enter = enter
    ..guard = guard
    ..superchat = superchat
    ..likes = likes
    ..popularity = popularity
    ..online = online
    ..watched = watched
    ..fans = fans
    ..fansClub = fansClub;
}

enum ConnState { idle, connecting, connected, reconnecting, error }

class LiveClient {
  LiveClient({required this.roomId, required this.api});

  final int roomId;
  final BilibiliApi api;

  RoomStats stats = RoomStats();
  RoomInfo? info;

  final _events = StreamController<LiveEvent>.broadcast();
  final _stats = StreamController<RoomStats>.broadcast();
  final _state = StreamController<ConnState>.broadcast();

  Stream<LiveEvent> get events => _events.stream;
  Stream<RoomStats> get statsStream => _stats.stream;
  Stream<ConnState> get stateStream => _state.stream;

  WebSocket? _ws;
  Timer? _heartbeat;
  Timer? _popularity;
  Timer? _idleWatch;
  Completer<void>? _done;
  bool _stopped = false;
  ConnState _stateValue = ConnState.idle;

  ConnState get state => _stateValue;
  bool get isConnected => _stateValue == ConnState.connected;

  /// 最近一次连接异常的具体原因，供 UI 排查展示。
  String lastError = '';

  void _setState(ConnState s) {
    _stateValue = s;
    if (!_state.isClosed) _state.add(s);
  }

  /// 主循环，内含重连。调用 [stop] 才会真正退出。
  Future<void> start() async {
    _stopped = false;
    var backoff = 1.0;
    while (!_stopped) {
      _setState(_stateValue == ConnState.idle
          ? ConnState.connecting
          : ConnState.reconnecting);
      try {
        await _listenOnce();
        backoff = 1.0;
      } catch (e) {
        if (_stopped) break;
        lastError = e.toString();
        _setState(ConnState.error);
      }
      if (_stopped) break;
      await Future<void>.delayed(Duration(milliseconds: (backoff * 1000).round()));
      backoff = (backoff * 2).clamp(1.0, _maxBackoff);
    }
    _setState(ConnState.idle);
  }

  void stop() {
    _stopped = true;
    _heartbeat?.cancel();
    _popularity?.cancel();
    _idleWatch?.cancel();
    _ws?.close();
    _ws = null;
  }

  Future<void> dispose() async {
    stop();
    await Future.wait([
      _events.close(),
      _stats.close(),
      _state.close(),
    ]);
  }

  Future<void> _listenOnce() async {
    info = await api.getRoomInfo(roomId);
    final room = info!.roomId;
    final creds = await api.getDanmuInfo(room);

    final ws = await WebSocket.connect(
      creds.wssUrl,
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Origin': 'https://live.bilibili.com',
      },
    );
    _ws = ws;

    ws.add(encodeAuth(
      roomId: room,
      token: creds.token,
      buvid: api.buvid3,
      uid: api.uid,
    ));

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: _heartbeatSeconds),
        (_) => ws.add(encodeHeartbeat()));

    _popularity?.cancel();
    _pollPopularity();
    _popularity = Timer.periodic(const Duration(seconds: _popularitySeconds),
        (_) => _pollPopularity());

    _done = Completer<void>();
    _resetIdleWatch();
    _setState(ConnState.connected);

    ws.listen(
      (data) {
        if (data is Uint8List) _handleFrame(data);
        _resetIdleWatch();
      },
      onError: (_) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );

    await _done!.future;
    _setState(ConnState.reconnecting);
  }

  void _finish() {
    if (!(_done?.isCompleted ?? true)) _done?.complete();
  }

  void _resetIdleWatch() {
    _idleWatch?.cancel();
    _idleWatch = Timer(const Duration(seconds: _idleTimeoutSeconds), () {
      // 长时间无数据，主动断开触发重连
      stop();
      _finish();
    });
  }

  void _handleFrame(Uint8List raw) {
    for (final p in iterMessages(raw)) {
      switch (p.op) {
        case opAuthReply:
          try {
            final ack = jsonDecode(utf8.decode(p.payload));
            if (ack['code'] != 0) {
              stop();
              _finish();
              return;
            }
          } catch (_) {}
          break;
        case opHeartbeatReply:
          // 载荷自 2024 起固定为 0x00000001，仅作保活确认
          break;
        case opMessage:
          try {
            final raw = jsonDecode(utf8.decode(p.payload));
            if (raw is Map) _handleMessage(raw.cast<String, dynamic>());
          } catch (_) {}
          break;
      }
    }
  }

  void _handleMessage(Map<String, dynamic> json) {
    final ev = normalize(json);
    if (ev == null) return; // 忽略不关心的 cmd，降低 UI 压力
    switch (ev.kind) {
      case EventKind.danmaku:
        stats.danmaku++;
        break;
      case EventKind.gift:
        stats.gift++;
        break;
      case EventKind.enter:
        stats.enter++;
        break;
      case EventKind.guard:
        stats.guard++;
        break;
      case EventKind.superchat:
        stats.superchat++;
        break;
      case EventKind.stats:
        _absorbStats(ev.extra);
        break;
      default:
        break;
    }
    // stats 类事件只用于刷新指标卡，不进入消息流，
    // 否则会被渲染成「匿名：」空行（其 user 为默认匿名、text 为空）。
    if (ev.kind != EventKind.stats && !_events.isClosed) _events.add(ev);
    _emitStats();
  }

  void _absorbStats(Map<String, dynamic> extra) {
    int? i(String k) => extra[k] is num ? (extra[k] as num).toInt() : null;
    stats.likes = i('likes') ?? stats.likes;
    stats.popularity = i('popularity') ?? stats.popularity;
    stats.online = i('online') ?? stats.online;
    stats.watched = i('watched') ?? stats.watched;
    stats.fans = i('fans') ?? stats.fans;
    stats.fansClub = i('fans_club') ?? stats.fansClub;
  }

  void _emitStats() {
    if (!_stats.isClosed) _stats.add(stats.copy());
  }

  Future<void> _pollPopularity() async {
    if (info == null) return;
    try {
      final data = await api.getRoomStats(info!.roomId);
      stats.popularity = data['popularity'] ?? stats.popularity;
      stats.fans = data['fans'] ?? stats.fans;
      _emitStats();
    } catch (_) {
      // 指标拉取失败不影响主链路
    }
  }
}
