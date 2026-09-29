import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/blive/normalize.dart';

void main() {
  group('ENTRY_EFFECT', () {
    test('去掉 <%...%> 占位符后仍有文案 → 正常输出', () {
      final ev = normalize({
        'cmd': 'ENTRY_EFFECT',
        'data': {
          'uid': 123,
          'face': 'https://x/a.jpg',
          'copy_writing': '欢迎舰长进入直播间',
        },
      });
      expect(ev, isNotNull);
      expect(ev!.kind, EventKind.enter);
      expect(ev.text, '欢迎舰长进入直播间');
      expect(ev.user.uid, 123);
    });

    test('整条只有占位符 → 返回 null（避免刷出「<%Ra1nFlo...%> 来了」）', () {
      // 实测报文长这样，占位符里的名字被服务端截断了，没有展示价值
      for (final tpl in [
        '<%Ra1nFlo...%> 来了',
        '<%Ra1nFlo...%>来了',
        '<%xxx%>',
        '<%%>   ',
        '<%昵称…%> 来了',
      ]) {
        final ev = normalize({
          'cmd': 'ENTRY_EFFECT',
          'data': {'uid': 1, 'copy_writing': tpl},
        });
        expect(ev, isNull, reason: '模板 $tpl 不该产生可见事件');
      }
    });

    test('占位符完整（未被截断）时保留两侧文案', () {
      final ev = normalize({
        'cmd': 'ENTRY_EFFECT',
        'data': {'uid': 1, 'copy_writing': '欢迎 <%完整昵称%> 进入直播间'},
      });
      expect(ev, isNotNull);
      expect(ev!.text, '欢迎 进入直播间');
    });

    test('多空格被压成一个，首尾去干净', () {
      final ev = normalize({
        'cmd': 'ENTRY_EFFECT',
        'data': {'uid': 1, 'copy_writing': '  <%a%>   来了   '},
      });
      expect(ev, isNotNull);
      expect(ev!.text, '来了');
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
  });
}
