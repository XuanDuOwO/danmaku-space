import 'package:http/http.dart' as http;

/// 把用户输入解析成直播间号。支持：
///   - 纯数字：`8385390`
///   - 直播链接：`https://live.bilibili.com/8385390?hotRank=0&session_id=...`
///   - 移动端分享短链：`https://b23.tv/xxxxxx`（跟随跳转后再提取）
///   - 带路径的链接：`https://live.bilibili.com/blanc/8385390`
///   - 分享文案混合文本：`【周六舰长车环节-哔哩哔哩直播】 https://b23.tv/LT9OlOW`
///     （从文本里自动抠出链接）
/// 解析不出时返回 null。
Future<int?> parseRoomInput(String input) async {
  final s = input.trim();
  if (s.isEmpty) return null;

  // 1) 纯数字
  if (RegExp(r'^\d{1,12}$').hasMatch(s)) {
    final v = int.tryParse(s);
    return (v != null && v > 0) ? v : null;
  }

  // 2) 链接：补全协议后解析。
  //    分享文案经常是「标题 + 链接」混在一起，先尝试从文本里抠出 URL，
  //    抠不出来再走原来的「整串当输入」兜底。
  var normalized = '';
  final urlM = RegExp(r'https?://[\w\-./?=%&#:~]+').firstMatch(s);
  if (urlM != null) {
    normalized = urlM.group(0)!;
  } else {
    final bareM = RegExp(
            r'(?:b23\.tv|bili2233\.cn|live\.bilibili\.com)/[\w\-./?=%&#:~]+')
        .firstMatch(s);
    if (bareM != null) {
      normalized = 'https://${bareM.group(0)}';
    } else if (s.startsWith('http://') || s.startsWith('https://')) {
      normalized = s;
    } else if (s.contains('.') || s.contains('/')) {
      normalized = 'https://$s';
    } else {
      return null;
    }
  }

  final parsed = Uri.tryParse(normalized);
  if (parsed == null) return null;
  var uri = parsed;

  // 3) 短链：跟随重定向，用最终 URL 再解析。
  //    注意 b23.tv 的行为不稳定：有时 302 跳转，有时直接 200 返回直播页
  //    HTML（此时最终 URL 仍是 b23.tv，但页面里有 "room_id":数字）。
  //    所以 URL 解析不出时，再兜底扫一遍响应体。
  final host = uri.host.toLowerCase();
  if (host == 'b23.tv' || host.endsWith('.b23.tv') || host.contains('bili2233.cn')) {
    try {
      final resp = await http
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 12));
      final finalUri = resp.request?.url ?? uri;
      final fromUrl = _extractRoomId(finalUri);
      if (fromUrl != null) return fromUrl;
      final fromBody = _roomIdFromBody(resp.body);
      if (fromBody != null) return fromBody;
    } catch (_) {
      // 跟随失败则用原始 uri 兜底
    }
  }

  return _extractRoomId(uri);
}

/// 从直播页 HTML 里抠房间号（b23.tv 直接吐页面时的兜底）。
int? _roomIdFromBody(String body) {
  if (body.isEmpty) return null;
  final patterns = [
    RegExp(r'"room_id"\s*:\s*(\d{1,12})'),
    RegExp(r'live\.bilibili\.com/(\d{1,12})'),
    RegExp(r'"roomId"\s*:\s*(\d{1,12})'),
    RegExp(r'roomid=(\d{1,12})'),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(body);
    if (m != null) {
      final v = int.tryParse(m.group(1)!);
      if (v != null && v > 0) return v;
    }
  }
  return null;
}

/// 从 URL 中取房间号：优先「/数字」形式（live.bilibili.com/8385390），
/// 其次取查询参数 room_id / roomid。
int? _extractRoomId(Uri uri) {
  for (final m in RegExp(r'/(\d{1,12})(?:/|$)').allMatches(uri.path)) {
    final v = int.tryParse(m.group(1)!);
    if (v != null && v > 0) return v;
  }
  for (final key in ['room_id', 'roomid', 'roomId']) {
    final q = uri.queryParameters[key];
    if (q != null) {
      final v = int.tryParse(q);
      if (v != null && v > 0) return v;
    }
  }
  // 兜底：整串里最长的数字片段
  final all = RegExp(r'\d{4,12}').allMatches(uri.toString());
  for (final m in all) {
    final v = int.tryParse(m.group(0)!);
    if (v != null && v > 0) return v;
  }
  return null;
}
