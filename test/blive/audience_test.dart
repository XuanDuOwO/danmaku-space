import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/blive/audience.dart';

void main() {
  group('parseAudienceMember', () {
    test('完整条目：解析 uid / 昵称 / 头像 / 贡献值 / 勋章', () {
      final m = parseAudienceMember({
        'userRank': 3,
        'uid': 29054101,
        'name': '翎羽睡不好',
        'face': 'http://i1.hdslb.com/bfs/face/abc.jpg',
        'score': 2231,
        'guard_level': 3,
        'wealth_level': 34,
        'is_mystery': false,
        'medalInfo': {
          'medalName': '嘉心糖',
          'level': 40,
          'guardLevel': 3,
        },
      })!;

      expect(m.uid, 29054101);
      expect(m.name, '翎羽睡不好');
      // http 必须升级成 https，否则 Android 9+ 加载不出图
      expect(m.face, 'https://i1.hdslb.com/bfs/face/abc.jpg');
      expect(m.score, 2231);
      expect(m.rank, 3);
      expect(m.guardLevel, 3);
      expect(m.guardLabel, '舰长');
      expect(m.wealthLevel, 34);
      expect(m.hasMedal, isTrue);
      expect(m.medalName, '嘉心糖');
      expect(m.medalLevel, 40);
    });

    test('缺少勋章字段时不崩，hasMedal 为 false', () {
      final m = parseAudienceMember({'uid': 1, 'name': 'A', 'score': 10})!;
      expect(m.hasMedal, isFalse);
      expect(m.guardLabel, '');
      expect(m.displayName, 'A');
    });

    test('uid 非法 → null', () {
      expect(parseAudienceMember({'uid': 0, 'name': 'A'}), isNull);
      expect(parseAudienceMember({'name': 'A'}), isNull);
      expect(parseAudienceMember('not a map'), isNull);
      expect(parseAudienceMember(null), isNull);
    });

    test('神秘人：没有昵称时显示占位名', () {
      final m = parseAudienceMember({
        'uid': 9,
        'is_mystery': true,
        'score': 1,
      })!;
      expect(m.displayName, '神秘人');
      expect(m.isMystery, isTrue);
    });

    test('数字被序列化成字符串时也能解析', () {
      final m = parseAudienceMember({
        'uid': '123',
        'score': '456',
        'guard_level': '2',
        'medalInfo': {'level': '7', 'medalName': '牌'},
      })!;
      expect(m.uid, 123);
      expect(m.score, 456);
      expect(m.guardLevel, 2);
      expect(m.medalLevel, 7);
    });
  });

  group('parseAudienceSnapshot', () {
    test('真实响应结构：onlineNum 与 OnlineRankItem', () {
      final page = parseAudienceSnapshot({
        'code': 0,
        'data': {
          'onlineNum': 245,
          'tips_text': '投喂、点赞、发弹幕均可上榜',
          'OnlineRankItem': [
            {'userRank': 1, 'uid': 11, 'name': '甲', 'score': 9},
            {'userRank': 2, 'uid': 22, 'name': '乙', 'score': 8},
          ],
        },
      });

      expect(page.online, 245);
      expect(page.tips, '投喂、点赞、发弹幕均可上榜');
      expect(page.members.map((m) => m.uid), [11, 22]);
      // 只有 2 条 < pageSize，说明没有下一页
      expect(page.hasMore, isFalse);
    });

    test('空的 OnlineRankItem 不是错误（在线人数仍有效）', () {
      final page = parseAudienceSnapshot({
        'code': 0,
        'data': {'onlineNum': 0, 'OnlineRankItem': <Object?>[]},
      });
      expect(page.online, 0);
      expect(page.members, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('兼容 onlineRankItem / list 两种字段名', () {
      expect(
        parseAudienceSnapshot({
          'data': {
            'onlineNum': 5,
            'onlineRankItem': [
              {'uid': 1, 'name': 'a'},
            ],
          },
        }).members.single.uid,
        1,
      );
      expect(
        parseAudienceSnapshot({
          'data': {
            'onlineNum': 5,
            'list': [
              {'uid': 2, 'name': 'b'},
            ],
          },
        }).members.single.uid,
        2,
      );
    });

    test('重复 uid 只保留一条', () {
      final page = parseAudienceSnapshot({
        'data': {
          'onlineNum': 2,
          'OnlineRankItem': [
            {'uid': 7, 'name': 'x'},
            {'uid': 7, 'name': 'x'},
          ],
        },
      });
      expect(page.members.length, 1);
    });

    test('本页拿满 pageSize 时标记还有下一页', () {
      final items = [
        for (var i = 1; i <= audiencePageSize; i++) {'uid': i, 'name': '$i'},
      ];
      final page = parseAudienceSnapshot({
        'data': {'onlineNum': 999, 'OnlineRankItem': items},
      });
      expect(page.members.length, audiencePageSize);
      expect(page.hasMore, isTrue);
    });

    test('整包结构异常 → 退化成空页而不是抛异常', () {
      for (final bad in <Object?>[null, 'x', 1, <Object?>[], {'data': null}]) {
        final page = parseAudienceSnapshot(bad);
        expect(page.online, 0);
        expect(page.members, isEmpty);
      }
    });
  });
}
