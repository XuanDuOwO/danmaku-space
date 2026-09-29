import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/blive/normalize.dart';

void main() {
  group('ENTRY_EFFECT', () {
    test('整条丢弃 —— 报文只是模板，渲染出来会是「有人 <%...%> 来了」', () {
      // 2026-09 实测报文（房间 13308358）：昵称塞在 <% %> 占位符里，
      // 而且常常被服务端截断（带 ... 或 …）。同一批进场在
      // INTERACT_WORD_V2 里已有完整记录，所以这里一律不产生事件。
      for (final tpl in [
        '<%滥殇生命%> 来了',
        '<%清风夜月一帘幽...%> 来了',
        '<%清风夜月一帘…%> 来了',
        '<%kaka7mi%> 来了',
        '',
      ]) {
        final ev = normalize({
          'cmd': 'ENTRY_EFFECT',
          'data': {'uid': 1733438, 'face': 'https://x/a.jpg', 'copy_writing': tpl},
        });
        expect(ev, isNull, reason: '模板 $tpl 不该产生可见事件');
      }
    });

    test('copy_writing_v2 同样丢弃（两条字段内容一致）', () {
      final ev = normalize({
        'cmd': 'ENTRY_EFFECT',
        'data': {'uid': 1, 'copy_writing_v2': '<%昵称%> 来了'},
      });
      expect(ev, isNull);
    });
  });

  group('其它 cmd 的基本形状', () {
    test('LIVE / PREPARING 用空昵称，避免渲染成「匿名：开播了」', () {
      final live = normalize({'cmd': 'LIVE'})!;
      expect(live.kind, EventKind.live);
      expect(live.text, '开播了');
      expect(live.user.name, '');

      final stop = normalize({'cmd': 'PREPARING'})!;
      expect(stop.text, '下播了');
    });

    test('无法识别的 cmd 返回 null', () {
      expect(normalize({'cmd': 'SOMETHING_ELSE'}), isNull);
      expect(normalize({}), isNull);
    });

    test('DANMU_MSG 解析出昵称与正文', () {
      final ev = normalize({
        'cmd': 'DANMU_MSG',
        'info': [
          [0, 1, 25, 16777215, 1700000000000, 0, 0, '', 0],
          '测试弹幕内容',
          [12345, '测试用户', 0, 0, 0, 10000, 1, ''],
          [21, '勋章名', '主播', 12345, 12345, 0, 0, '', 0, 0, 0],
          [1, 0, 9868950, '>50000', 0],
          ['', ''],
          0,
          0,
          null,
          {'ts': 1},
          0,
          0,
          0,
          0,
          '{}',
          {'extra': jsonEncode({'emots': null})},
        ],
      });
      expect(ev, isNotNull);
      expect(ev!.kind, EventKind.danmaku);
      expect(ev.text, '测试弹幕内容');
      expect(ev.user.name, '测试用户');
      expect(ev.user.uid, 12345);
    });

    test('SEND_GIFT_V2 的 uid 取自 pb[1]，并带出 gift_id 与单价', () {
      // 用真实报文片段（见 tool 探针采集的样本）太脆弱，
      // 这里直接构造与实测结构一致的 pb。
      final pb = _encodePb({
        1: 1906052049,
        2: '测试送礼人',
        3: 'https://x/face.jpg',
        10: {
          1: 31164,
          2: '粉丝团灯牌',
          3: 1,
          5: 100,
          8: 'gold',
          10: 1790668068,
          18: '投喂',
        },
      });
      final ev = normalize({
        'cmd': 'SEND_GIFT_V2',
        'data': {'dmscore': 1, 'pb': base64Encode(pb)},
      })!;

      expect(ev.kind, EventKind.gift);
      expect(ev.user.uid, 1906052049);
      expect(ev.user.name, '测试送礼人');
      expect(ev.extra['gift_id'], 31164);
      expect(ev.extra['gift_name'], '粉丝团灯牌');
      expect(ev.extra['price'], 100);
      expect(ev.extra['coin_type'], 'gold');
      expect(ev.extra['count'], 1);
    });
  });
}

// ---------------------------------------------------------------- 测试用 pb 编码

/// 极简 protobuf 编码器（只支持本项目报文用到的 varint 与
/// length-delimited 两种线型），用来在测试里构造与实测一致的报文。
List<int> _encodePb(Map<int, Object> fields) {
  final out = <int>[];
  fields.forEach((field, value) {
    if (value is int) {
      out.addAll(_varint((field << 3) | 0));
      out.addAll(_varint(value));
    } else if (value is String) {
      final bytes = utf8.encode(value);
      out.addAll(_varint((field << 3) | 2));
      out.addAll(_varint(bytes.length));
      out.addAll(bytes);
    } else if (value is Map<int, Object>) {
      final bytes = _encodePb(value);
      out.addAll(_varint((field << 3) | 2));
      out.addAll(_varint(bytes.length));
      out.addAll(bytes);
    }
  });
  return out;
}

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  while (x >= 0x80) {
    out.add((x & 0x7F) | 0x80);
    x >>= 7;
  }
  out.add(x);
  return out;
}
