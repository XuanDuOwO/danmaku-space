import 'dart:convert';
import 'dart:typed_data';

/// 极简 protobuf 解析器
///
/// B站新版 INTERACT_WORD_V2（进场）与 SEND_GIFT_V2（礼物）已改为 protobuf，
/// 明文字段不存在，载荷位于 data.pb（base64）。
///
/// 实测字段编号：
///   INTERACT_WORD_V2：1=uid 2=用户名 3=头像 6=room_id
///                     9=勋章{2:等级,3:名称} 22={1:uid,2:{1:名,2:头像},3:勋章}
///                     23={2:进场文案}
///   SEND_GIFT_V2    ：2=用户名 3=头像
///                     10={1:gift_id,2:礼物名,3:数量,5:单价,8:coin_type,
///                         10:秒级时间戳,18:action,29:主播} 34={1:uid}

/// 读取 varint，返回 (值, 新的偏移量)。
(int, int) _readVarint(Uint8List b, int i) {
  var result = 0;
  var shift = 0;
  while (true) {
    if (i >= b.length) throw RangeError('varint overflow');
    final byte = b[i++];
    result |= (byte & 0x7F) << shift;
    if ((byte & 0x80) == 0) return (result, i);
    shift += 7;
  }
}

/// 把 protobuf 二进制扫成 {field_number: value}。
Map<int, dynamic> pbDecode(Uint8List buf, {int depth = 0, int maxDepth = 5}) {
  final out = <int, List<dynamic>>{};
  var i = 0;

  while (i < buf.length) {
    int tag;
    try {
      (tag, i) = _readVarint(buf, i);
    } catch (_) {
      break;
    }
    final fieldNo = tag >> 3;
    final wireType = tag & 7;

    dynamic value;
    try {
      switch (wireType) {
        case 0: // varint
          final r = _readVarint(buf, i);
          value = r.$1;
          i = r.$2;
        case 1: // 64-bit
          value = Uint8List.sublistView(buf, i, i + 8);
          i += 8;
        case 2: // length-delimited
          final ln = _readVarint(buf, i);
          i = ln.$2;
          value = Uint8List.sublistView(buf, i, i + ln.$1);
          i += ln.$1;
        case 5: // 32-bit
          value = Uint8List.sublistView(buf, i, i + 4);
          i += 4;
        default: // wire type 3/4 已废弃
          return {for (final e in out.entries) e.key: e.value.length == 1 ? e.value.first : e.value};
      }
    } catch (_) {
      break;
    }

    if (value is Uint8List) {
      String? text;
      try {
        text = utf8.decode(value, allowMalformed: false);
      } catch (_) {
        text = null;
      }
      if (text != null && (text.isEmpty || _isPrintable(text))) {
        out.putIfAbsent(fieldNo, () => []).add(text);
      } else if (depth < maxDepth) {
        out.putIfAbsent(fieldNo, () => []).add(pbDecode(value, depth: depth + 1, maxDepth: maxDepth));
      } else {
        out.putIfAbsent(fieldNo, () => []).add('<bytes ${value.length}>');
      }
    } else {
      out.putIfAbsent(fieldNo, () => []).add(value);
    }
  }

  return {for (final e in out.entries) e.key: e.value.length == 1 ? e.value.first : e.value};
}

bool _isPrintable(String s) {
  // 只把可打印的字节串当作字符串字段，其余继续按嵌套 message 递归
  for (var r = 0; r < s.length; r++) {
    final c = s.codeUnitAt(r);
    if (c < 0x20 || c == 0x7F) return false;
  }
  return true;
}

/// 按字段编号逐层取值，任一层缺失返回 [defaultValue]。
dynamic pbGet(Map<int, dynamic> obj, List<int> path, {dynamic defaultValue}) {
  dynamic cur = obj;
  for (final key in path) {
    if (cur is! Map) return defaultValue;
    cur = cur[key];
    if (cur == null) return defaultValue;
  }
  return cur;
}
