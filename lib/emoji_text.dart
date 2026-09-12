import 'package:flutter/material.dart';

/// 表情文本渲染（弹幕空间页与弹幕记录页共用）。
///
/// 数据来源全部是 B站直播间接口，不使用任何第三方表情表：
///   1. [inline] 本条弹幕自带的表情：`info[0][15].extra.emots`
///      （实测只覆盖基础表情，如 `[花]`、`[大笑]`）；
///   2. [room] 当前房间的表情表：`GetEmoticons?platform=pc&room_id=`，
///      覆盖直播通用表情、UP 主大表情与灯牌横幅表情。
///
/// 两种文本形态都要支持（这是实测差异，不是猜测）：
///   - App / 接口发送：文本带中括号，如 `[妙啊]`；
///   - **网页端发送灯牌：整条文本就是表情名、不带中括号**，如 `中奖喷雾`
///     （B站 web 端发灯牌时 msg 直接是名字，服务端也不回填 emots）。
///
/// 两处都查不到的占位符原样显示为文本，与 B站客户端行为一致。
List<InlineSpan> buildEmojiSpans({
  required String text,
  TextStyle? style,
  Map<String, String>? inline,
  Map<String, String>? room,
  double height = 17,
}) {
  // 情形一：整条文本恰好是一个表情名（网页端发的灯牌），整体替换成图。
  final bare = text.trim();
  if (bare.isNotEmpty && !bare.contains('[')) {
    final u = _lookup(bare, inline, room);
    if (u != null) return [_emoteSpan(u, text, style, height)];
  }

  // 情形二：扫描文本中的 [名字] 占位符。
  final rx = RegExp(r'\[([^\]]{1,32})\]');
  final spans = <InlineSpan>[];
  var matched = false;
  var last = 0;
  for (final m in rx.allMatches(text)) {
    final token = m.group(0)!;
    final inner = m.group(1)!;
    final url = _lookupDirect(token, inner, inline, room);
    if (url == null) {
      debugPrint('[emoji] 未命中 $token  弹幕表=${inline?.length ?? 0} '
          '房间表=${room?.length ?? 0}');
      continue;
    }
    matched = true;
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start), style: style));
    }
    spans.add(_emoteSpan(url, token, style, height));
    last = m.end;
  }
  if (!matched) return [TextSpan(text: text, style: style)];
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: style));
  }
  return spans;
}

/// 按名字查表：同时兼容「带中括号」与「不带中括号」两种键。
String? _lookup(
    String name, Map<String, String>? inline, Map<String, String>? room) {
  return inline?[name] ??
      inline?['[$name]'] ??
      room?[name] ??
      room?['[$name]'];
}

/// 括号匹配时用：原文 token（`[X]`）与内层名字（`X`）都试一遍。
String? _lookupDirect(String token, String inner, Map<String, String>? inline,
    Map<String, String>? room) {
  return inline?[token] ??
      inline?[inner] ??
      room?[token] ??
      room?[inner];
}

/// 单个表情的内联图片。
/// 只给高度、不给宽度，让 Flutter 按图片原始比例算宽度：
/// 官方直播表情多为 200×60 / 138×60 等宽图（灯牌横幅），强制定宽会被压扁。
/// 外层 maxWidth 兜底，避免超宽表情撑破行宽。
WidgetSpan _emoteSpan(
    String url, String fallback, TextStyle? style, double height) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 56),
      child: Image.network(
        url,
        height: height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => Text(fallback, style: style),
      ),
    ),
  );
}
