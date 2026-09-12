import 'dart:convert';

import 'package:crypto/crypto.dart';

/// WBI 签名
///
/// 2025-06 起 B站对 getDanmuInfo 等接口启用 WBI 风控，缺签名或 buvid3
/// 会直接返回 `{"code": -352}`。签名流程：
///   1. nav 取当日 img_key / sub_key（每日轮换）
///   2. img_key + sub_key 按固定置换表重排，截前 32 位得 mixin_key
///   3. 追加 wts（秒级时间戳），排序，过滤 value 中的 !'()* 字符
///   4. urlencode 拼接 mixin_key 取 MD5 得 w_rid

const List<int> mixinKeyEncTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, //
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, //
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, //
  22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52, //
];

String getMixinKey(String raw) {
  final sb = StringBuffer();
  for (final i in mixinKeyEncTab) {
    sb.write(raw[i]);
  }
  return sb.toString().substring(0, 32);
}

/// 返回带 wts / w_rid 的完整查询参数。
Map<String, String> wbiSign(
  Map<String, dynamic> params,
  String imgKey,
  String subKey, {
  int? timestamp,
}) {
  final mixinKey = getMixinKey(imgKey + subKey);
  final signed = <String, String>{
    for (final e in params.entries)
      e.key: e.value.toString().replaceAll(RegExp(r"[!'()*]"), ''),
  };
  signed['wts'] = (timestamp ??
          DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond)
      .toString();

  final keys = signed.keys.toList()..sort();
  final query = keys
      .map((k) =>
          '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(signed[k]!)}')
      .join('&');
  signed['w_rid'] = md5.convert(utf8.encode(query + mixinKey)).toString();
  return signed;
}
