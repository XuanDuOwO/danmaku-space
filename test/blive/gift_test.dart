import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/blive/gift.dart';

void main() {
  group('GiftTable.parse', () {
    test('解析 global_gift.list 与 data.list，并给出 id→单价', () {
      final t = GiftTable.parse({
        'code': 0,
        'data': {
          'global_gift': {
            'list': [
              {'id': 34961, 'name': '爱心小熊', 'price': 52000, 'coin_type': 'gold'},
              {'id': 31214, 'name': '牛哇', 'price': 100, 'coin_type': 'gold'},
            ],
          },
          'list': [
            {'id': 31164, 'name': '粉丝团灯牌', 'price': 100, 'coin_type': 'gold'},
          ],
        },
      });

      expect(t.length, 3);
      expect(t.lookup(id: 34961)!.price, 52000);
      expect(t.lookup(id: 31164)!.name, '粉丝团灯牌');
      // 52000 金瓜子 = 52 元
      expect(t.lookup(id: 34961)!.yuan, 52.0);
      expect(t.lookup(id: 34961)!.isPaid, isTrue);
    });

    test('只有名字没有 id 时也能按名字查到（报文常缺 gift_id）', () {
      final t = GiftTable.parse({
        'data': {
          'global_gift': {
            'list': [
              {'id': 34961, 'name': '爱心小熊', 'price': 52000, 'coin_type': 'gold'},
            ],
          },
        },
      });
      expect(t.lookup(name: '爱心小熊')!.price, 52000);
      // 名字两头带空格也要命中
      expect(t.lookup(name: ' 爱心小熊 ')!.price, 52000);
      expect(t.lookup(name: '不存在的礼物'), isNull);
    });

    test('同名礼物优先保留付费的那条', () {
      // B站面板里「人气票」同时存在付费与免费两种 id
      final t = GiftTable.parse({
        'data': {
          'global_gift': {
            'list': [
              {'id': 33987, 'name': '人气票', 'price': 0, 'coin_type': 'silver'},
              {'id': 33988, 'name': '人气票', 'price': 100, 'coin_type': 'gold'},
            ],
          },
        },
      });
      expect(t.lookup(name: '人气票')!.isPaid, isTrue);
      expect(t.lookup(name: '人气票')!.price, 100);
    });

    test('银瓜子（免费）礼物 isPaid 为 false，金额记 0', () {
      final t = GiftTable.parse({
        'data': {
          'global_gift': {
            'list': [
              {'id': 33666, 'name': '辣条', 'price': 100, 'coin_type': 'silver'},
            ],
          },
        },
      });
      final info = t.lookup(id: 33666)!;
      expect(info.coinType, 'silver');
      expect(info.isPaid, isFalse);
    });

    test('结构异常 → 空表而不是抛异常', () {
      for (final bad in <Object?>[null, 'x', 1, <Object?>[], {'data': null}]) {
        final t = GiftTable.parse(bad);
        expect(t.isEmpty, isTrue);
        expect(t.lookup(id: 1, name: 'x'), isNull);
      }
    });

    test('缺 id / 缺名字的条目被跳过', () {
      final t = GiftTable.parse({
        'data': {
          'global_gift': {
            'list': [
              {'name': '没有id', 'price': 100},
              {'id': 111, 'price': 100},
              {'id': 222, 'name': '正常', 'price': 100, 'coin_type': 'gold'},
            ],
          },
        },
      });
      expect(t.length, 1);
      expect(t.lookup(id: 222)!.name, '正常');
    });
  });

  group('GiftAccumulator', () {
    GiftInfo info(int price) =>
        GiftInfo(id: 1, name: 'x', price: price, coinType: 'gold');

    test('多批数量按增量累加（实测连击 num 是增量而非累计）', () {
      final a = GiftAccumulator();
      // 同一个 combo 连续四条 num=1 —— 总数必须是 4，不是 1
      for (var i = 0; i < 4; i++) {
        a.add(name: '粉丝团灯牌', num: 1, info: info(100));
      }
      final s = a.snapshot();
      expect(s.items.single.count, 4);
      expect(s.items.single.gold, 400);
      expect(s.paidCount, 4);
      expect(s.totalGold, 400);
      expect(s.totalYuan, 0.4);
    });

    test('一次投喂多个（num=10）按单价乘数量', () {
      final a = GiftAccumulator();
      a.add(name: '爱心小熊', num: 3, info: info(52000));
      final s = a.snapshot();
      expect(s.items.single.count, 3);
      expect(s.items.single.maxBatch, 3);
      expect(s.totalGold, 156000);
      expect(s.totalYuan, 156.0);
    });

    test('免费礼物计入数量但不计入金额', () {
      final a = GiftAccumulator();
      a.add(
        name: '辣条',
        num: 5,
        info: const GiftInfo(
            id: 1, name: '辣条', price: 100, coinType: 'silver'),
      );
      final s = a.snapshot();
      expect(s.freeCount, 5);
      expect(s.paidCount, 0);
      expect(s.totalGold, 0);
      expect(s.items.single.paid, isFalse);
    });

    test('价格表里没有的礼物：计入数量并标记 unknownCount，金额记 0', () {
      final a = GiftAccumulator();
      a.add(name: '新活动礼物', num: 2, info: null);
      final s = a.snapshot();
      expect(s.unknownCount, 1);
      expect(s.totalGold, 0);
      expect(s.items.single.count, 2);
      expect(s.items.single.paid, isFalse);
    });

    test('按价值降序排序，同价值按数量降序', () {
      final a = GiftAccumulator();
      a.add(name: '小花花', num: 1, info: info(100));
      a.add(name: '爱心小熊', num: 1, info: info(52000));
      a.add(name: '牛哇', num: 9, info: info(100));
      final names = a.snapshot().items.map((e) => e.name).toList();
      expect(names, ['爱心小熊', '牛哇', '小花花']);
    });

    test('非法输入被忽略（空名 / 非正数）', () {
      final a = GiftAccumulator();
      a.add(name: '', num: 1, info: info(100));
      a.add(name: 'x', num: 0, info: info(100));
      a.add(name: 'x', num: -3, info: info(100));
      expect(a.snapshot().isEmpty, isTrue);
    });

    test('clear 后回到空状态', () {
      final a = GiftAccumulator();
      a.add(name: '牛哇', num: 2, info: info(100));
      expect(a.totalYuan, greaterThan(0));
      a.clear();
      expect(a.snapshot().isEmpty, isTrue);
      expect(a.totalYuan, 0);
    });

    test('paidItems 只含付费礼物', () {
      final a = GiftAccumulator();
      a.add(name: '牛哇', num: 1, info: info(100));
      a.add(
        name: '辣条',
        num: 100,
        info: const GiftInfo(
            id: 2, name: '辣条', price: 100, coinType: 'silver'),
      );
      final s = a.snapshot();
      expect(s.items.length, 2);
      expect(s.paidItems.length, 1);
      expect(s.paidItems.single.name, '牛哇');
    });

    test('汇总可 JSON 往返（用于以后持久化本场统计）', () {
      final a = GiftAccumulator();
      a.add(name: '爱心小熊', num: 2, info: info(52000));
      final s = a.snapshot();
      final back = GiftSummary.fromJson(s.toJson());
      expect(back.totalGold, s.totalGold);
      expect(back.items.single.count, 2);
      expect(back.items.single.name, '爱心小熊');
    });
  });

  group('formatYuan', () {
    test('0 与负数显示 ¥0', () {
      expect(formatYuan(0), '¥0');
      expect(formatYuan(-1), '¥0');
    });

    test('整数不显示小数', () {
      expect(formatYuan(52), '¥52');
      expect(formatYuan(1234), '¥1,234'); // 千分位
    });

    test('小于 1 元保留两位，其余保留一位', () {
      expect(formatYuan(0.05), '¥0.05');
      expect(formatYuan(0.4), '¥0.40');
      expect(formatYuan(12.5), '¥12.5');
      expect(formatYuan(12345.6), '¥12,345.6');
    });
  });
}
