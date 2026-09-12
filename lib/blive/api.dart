import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'wbi.dart';

/// B站 HTTP 接口封装：身份初始化、房间解析、弹幕凭据获取

const String userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const String _apiBase = 'https://api.live.bilibili.com';
const String _mainBase = 'https://api.bilibili.com';

const String _apiRoomInit = '$_apiBase/room/v1/Room/room_init';
const String _apiRoomGetInfo = '$_apiBase/room/v1/Room/get_info';
const String _apiRoomInfo = '$_apiBase/xlive/web-room/v1/index/getInfoByRoom';
/// 主播（UP 主）在房间内的基本信息，含 uname / face。
/// 免 WBI 签名，用作 getInfoByRoom 被风控（-352）时的主播信息兜底。
const String _apiAnchorInRoom =
    '$_apiBase/live_user/v1/UserInfo/get_anchor_in_room';
const String _apiDanmuInfo = '$_apiBase/xlive/web-room/v1/index/getDanmuInfo';
const String _apiSpi = '$_mainBase/x/frontend/finger/spi';
const String _apiNav = '$_mainBase/x/web-interface/nav';
/// 直播间可用的表情包（通用表情 / UP主大表情 / 房间专属表情）。
/// 与服务端下发的 info[0][15].extra.emots 互补，二者都不依赖第三方数据。
const String _apiEmoticons =
    '$_apiBase/xlive/web-ucenter/v2/emoticon/GetEmoticons';
const String _apiQrGenerate =
    'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
const String _apiQrPoll =
    'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';

/// WBI 密钥每日轮换，缓存一小时即可。
const int _wbiKeyTtl = 3600;

class ApiException implements Exception {
  final String endpoint;
  final int code;
  final String message;
  const ApiException(this.endpoint, this.code, this.message);
  @override
  String toString() => '$endpoint -> code=$code message=$message';
}

class RoomInfo {
  final int roomId;
  final int shortId;
  final int uid;
  final String title;
  final String areaName;
  final String parentAreaName;
  final String cover;
  final int liveStatus; // 0 未开播 1 直播中 2 轮播
  final String anchorName;
  final String anchorFace;

  const RoomInfo({
    required this.roomId,
    this.shortId = 0,
    this.uid = 0,
    this.title = '',
    this.areaName = '',
    this.parentAreaName = '',
    this.cover = '',
    this.liveStatus = 0,
    this.anchorName = '',
    this.anchorFace = '',
  });

  bool get isLive => liveStatus == 1;
}

class DanmuCredentials {
  final String token;
  final String host;
  final int wssPort;
  final DateTime expiresAt;

  const DanmuCredentials({
    required this.token,
    required this.host,
    required this.wssPort,
    required this.expiresAt,
  });

  String get wssUrl => 'wss://$host:$wssPort/sub';
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class Profile {
  final bool isLogin;
  final String name;
  final int uid;

  /// 头像 URL（来自 nav 接口的 data.face），用于首页右上角展示。
  final String face;
  const Profile({
    required this.isLogin,
    this.name = '',
    this.uid = 0,
    this.face = '',
  });
}

class BilibiliApi {
  /// [cookie] 登录态（含 SESSDATA）。带登录态才能解除弹幕用户名脱敏，
  /// 游客身份拿到的昵称会显示成 `j***`。
  BilibiliApi({String cookie = '', http.Client? client})
      : _cookie = cookie,
        _client = client ?? http.Client();

  String _cookie;
  final http.Client _client;

  String buvid3 = '';
  String buvid4 = '';
  int uid = 0;
  String uname = '';

  String _imgKey = '';
  String _subKey = '';
  int _wbiFetchedAt = 0;

  String get cookie => _cookie;
  set cookie(String v) => _cookie = v;

  String get cookieHeader {
    final parts = <String>[
      if (buvid3.isNotEmpty) 'buvid3=$buvid3',
      if (buvid4.isNotEmpty) 'buvid4=$buvid4',
      if (_cookie.trim().isNotEmpty) _cookie.trim().replaceAll(RegExp(r';$'), ''),
    ];
    return parts.join('; ');
  }

  void dispose() => _client.close();

  Map<String, String> get _headers => {
        'User-Agent': userAgent,
        'Referer': 'https://live.bilibili.com/',
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      };

  /// 图片地址统一转 https。
  /// B站接口返回的头像/封面多为 http://i0.hdslb.com/...，而 Android 9+ 默认
  /// 禁止明文流量（iOS 的 ATS 同理），直接用会导致图片加载失败。
  static String secureUrl(String u) =>
      u.startsWith('http://') ? 'https://${u.substring(7)}' : u;

  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, String>? params,
    Set<int> allowedCodes = const {},
  }) async {
    final uri = Uri.parse(url).replace(queryParameters: params);
    final resp = await _client.get(uri, headers: _headers).timeout(
          const Duration(seconds: 15),
        );
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final code = data['code'];
    if (code != null && code != 0) {
      // nav 未登录返回 -101，但 data.wbi_img 仍然有效，需放行
      if (!allowedCodes.contains(code)) {
        throw ApiException(url, code as int,
            (data['message'] ?? data['msg'] ?? '').toString());
      }
    }
    return data;
  }

  // ------------------------------------------------------------- 身份初始化
  Future<void> ensureBuvid({bool force = false}) async {
    if (buvid3.isNotEmpty && !force) return;
    final data = await _getJson(_apiSpi);
    buvid3 = data['data']['b_3'] as String;
    buvid4 = (data['data']['b_4'] ?? '') as String;
  }

  Future<void> ensureWbiKeys({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_imgKey.isNotEmpty && now - _wbiFetchedAt < _wbiKeyTtl && !force) return;
    await ensureBuvid();
    final data = await _getJson(_apiNav, allowedCodes: {-101});
    final wbi = (data['data']?['wbi_img']) as Map<String, dynamic>?;
    if (wbi == null) throw const ApiException(_apiNav, -1, 'nav 未返回 wbi_img');
    _imgKey = (wbi['img_url'] as String).split('/').last.split('.').first;
    _subKey = (wbi['sub_url'] as String).split('/').last.split('.').first;
    _wbiFetchedAt = now;
    uid = (data['data']?['mid'] as int?) ?? 0;
    uname = (data['data']?['uname'] as String?) ?? '';
  }

  Future<void> ensureIdentity() async {
    await ensureBuvid();
    await ensureWbiKeys();
  }

  // ------------------------------------------------------------- 业务接口
  Future<Map<String, dynamic>> roomInit(int roomId) async {
    await ensureIdentity();
    final data = await _getJson(_apiRoomInit, params: {'id': '$roomId'});
    return data['data'] as Map<String, dynamic>;
  }

  Future<RoomInfo> getRoomInfo(int roomId) async {
    final init = await roomInit(roomId);
    final realId = (init['room_id'] as int?) ?? roomId;

    Map<String, dynamic> ri = {};
    Map<String, dynamic> anchor = {};
    try {
      // getInfoByRoom 同样启用了 WBI 风控，缺签名返回 -352
      final info = await _getJson(
        _apiRoomInfo,
        params: wbiSign({'room_id': realId}, _imgKey, _subKey),
      );
      ri = (info['data']?['room_info'] as Map<String, dynamic>?) ?? {};
      anchor = (info['data']?['anchor_info']?['base_info']
              as Map<String, dynamic>?) ??
          {};
    } catch (_) {
      // 展示信息失败不应阻断弹幕抓取
    }

    // 兜底：getInfoByRoom 启用了 WBI 风控，签名缺失/失效时 anchor_info 会是空的。
    // 换一个免签名的接口补齐主播昵称与头像。
    if ((anchor['uname'] as String?)?.isNotEmpty != true ||
        (anchor['face'] as String?)?.isNotEmpty != true) {
      try {
        final a = await _getJson(
          _apiAnchorInRoom,
          params: {'roomid': '$realId'},
          allowedCodes: {-400, -404},
        );
        final info = (a['data']?['info'] as Map<String, dynamic>?) ?? {};
        if ((anchor['uname'] as String?)?.isNotEmpty != true &&
            (info['uname'] as String?)?.isNotEmpty == true) {
          anchor['uname'] = info['uname'];
        }
        if ((anchor['face'] as String?)?.isNotEmpty != true &&
            (info['face'] as String?)?.isNotEmpty == true) {
          anchor['face'] = info['face'];
        }
      } catch (_) {
        // 兜底失败就维持空值，顶栏会自动退化为占位头像。
      }
    }

    return RoomInfo(
      roomId: realId,
      shortId: (init['short_id'] as int?) ?? 0,
      uid: (init['uid'] as int?) ?? 0,
      title: (ri['title'] as String?) ?? '',
      areaName: (ri['area_name'] as String?) ?? '',
      parentAreaName: (ri['parent_area_name'] as String?) ?? '',
      cover: (ri['cover'] as String?) ?? '',
      liveStatus:
          (init['live_status'] as int?) ?? (ri['live_status'] as int?) ?? 0,
      anchorName: (anchor['uname'] as String?) ?? '',
      anchorFace: secureUrl((anchor['face'] as String?) ?? ''),
    );
  }

  Future<DanmuCredentials> getDanmuInfo(int roomId) async {
    await ensureWbiKeys();
    final data = await _getJson(
      _apiDanmuInfo,
      params: wbiSign({'id': roomId, 'type': 0}, _imgKey, _subKey),
    );
    final hosts = data['data']['host_list'] as List<dynamic>;
    if (hosts.isEmpty) {
      throw const ApiException(_apiDanmuInfo, -1, 'host_list 为空');
    }
    final host = hosts.first as Map<String, dynamic>;
    return DanmuCredentials(
      token: data['data']['token'] as String,
      host: host['host'] as String,
      wssPort: (host['wss_port'] as int?) ?? 443,
      expiresAt: DateTime.now().add(const Duration(minutes: 20)),
    );
  }

  /// 人气值与粉丝数：心跳回复已不再携带人气值，改由该接口补充。
  Future<Map<String, int>> getRoomStats(int roomId) async {
    final data = await _getJson(_apiRoomGetInfo, params: {'room_id': '$roomId'});
    final d = (data['data'] as Map<String, dynamic>?) ?? {};
    return {
      'popularity': (d['online'] as int?) ?? 0,
      'fans': (d['attention'] as int?) ?? 0,
    };
  }

  Future<Profile> getProfile() async {
    final data = await _getJson(_apiNav, allowedCodes: {-101});
    final d = (data['data'] as Map<String, dynamic>?) ?? {};
    return Profile(
      isLogin: d['isLogin'] == true,
      name: (d['uname'] as String?) ?? '',
      uid: (d['mid'] as int?) ?? 0,
      face: secureUrl((d['face'] as String?) ?? ''),
    );
  }

  /// 拉取直播间可用的表情包，返回 [token] → 图片 URL。
  ///
  /// 这是直播间接口下发的真实数据，作为 [info[0][15].extra.emots] 的补充：
  ///   - emots 只回填 B站基础表情（emoticon_unique 形如 emoji_209，如 [花]、[大笑]）；
  ///   - 直播通用 / UP主 / 房间专属表情（official_xxx，如 [妙啊] 及灯牌系列）
  ///     不会出现在 emots 里，必须由该接口补齐。
  Future<Map<String, String>> getEmoticons(int roomId) async {
    // 该接口对未登录/缺 buvid 的请求会返回空包，先补齐设备指纹再拉。
    await ensureBuvid();
    final data = await _getJson(_apiEmoticons,
        params: {'platform': 'pc', 'room_id': '$roomId'},
        allowedCodes: {-101, -400, -500});
    final out = <String, String>{};
    final d = data['data'];
    final pkgs = (d is Map ? d['data'] : null);
    if (pkgs is! List) return out;
    for (final pkg in pkgs) {
      if (pkg is! Map) continue;
      final emotes = pkg['emoticons'];
      if (emotes is! List) continue;
      for (final e in emotes) {
        if (e is! Map) continue;
        final tok = e['emoji'];
        var url = e['gif_url'] ?? e['url'];
        if (tok is! String || tok.isEmpty) continue;
        if (url is! String || url.isEmpty) continue;
        if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
        out['[$tok]'] = url as String;
      }
    }
    return out;
  }
}

/// 扫码登录：容器需要保留各次请求回落的 Cookie，这里用轻量实现。
class QrLoginSession {
  final http.Client _client = http.Client();
  String buvid3 = '';
  String _qrcodeKey = '';

  Map<String, String> get _cookieHeader => {'Cookie': 'buvid3=$buvid3'};

  Future<String> generate() async {
    await _ensureBuvid();
    final resp = await _client.get(
      Uri.parse(_apiQrGenerate),
      headers: {'User-Agent': userAgent, ..._cookieHeader},
    );
    _absorbCookies(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['code'] != 0) throw ApiException(_apiQrGenerate, -1, '生成失败');
    _qrcodeKey = data['data']['qrcode_key'] as String;
    return data['data']['url'] as String;
  }

  /// 返回 (状态码, 描述)。0 表示成功。
  Future<(int, String, String)> poll() async {
    final resp = await _client.get(
      Uri.parse('$_apiQrPoll?qrcode_key=$_qrcodeKey'),
      headers: {'User-Agent': userAgent, ..._cookieHeader},
    );
    _absorbCookies(resp);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final d = (data['data'] as Map<String, dynamic>?) ?? {};
    final code = (d['code'] as int?) ?? -1;
    final message = (d['message'] as String?) ?? '';
    if (code == 0) {
      return (0, '登录成功', _cookies['SESSDATA'] ?? '');
    }
    return (code, message, '');
  }

  /// 成功后的完整 cookie 串，供 BilibiliApi 使用。
  String get cookie => _cookies.entries
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  final Map<String, String> _cookies = {};

  void _absorbCookies(http.Response resp) {
    final raw = resp.headers['set-cookie'];
    if (raw == null) return;
    for (final part in raw.split(RegExp(r',(?=[^;]+=)'))) {
      final pair = part.split(';').first;
      if (!pair.contains('=')) continue;
      final idx = pair.indexOf('=');
      final k = pair.substring(0, idx).trim();
      final v = pair.substring(idx + 1).trim();
      if (k == 'SESSDATA' && v.isEmpty) continue; // 过期标记
      _cookies[k] = v;
      if (k == 'buvid3') buvid3 = v;
    }
  }

  Future<void> _ensureBuvid() async {
    if (buvid3.isNotEmpty) return;
    final resp = await _client.get(Uri.parse(_apiSpi),
        headers: {'User-Agent': userAgent});
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    buvid3 = data['data']['b_3'] as String;
  }

  void dispose() => _client.close();
}
