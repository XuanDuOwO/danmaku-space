import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/room_ref.dart';

void main() {
  test('纯数字房间号', () async {
    expect(await parseRoomInput('32060092'), 32060092);
  });

  test('完整直播链接', () async {
    expect(
      await parseRoomInput(
          'https://live.bilibili.com/8385390?hotRank=0&session_id=abc'),
      8385390,
    );
    expect(
      await parseRoomInput('https://live.bilibili.com/blanc/22957791'),
      22957791,
    );
  });

  test('分享文案混合文本（标题 + b23.tv 短链）', () async {
    // 用户实测反馈的格式
    expect(
      await parseRoomInput(
          '【周六舰长车环节-哔哩哔哩直播】 https://b23.tv/LT9OlOW'),
      1862084064,
    );
    // 无空格 / 中文紧贴链接
    expect(
      await parseRoomInput('链接https://b23.tv/LT9OlOW复制这条信息'),
      1862084064,
    );
    // 无协议头裸短链
    expect(await parseRoomInput('b23.tv/LT9OlOW'), 1862084064);
  });

  test('解析不出返回 null', () async {
    expect(await parseRoomInput('随便一段文字'), isNull);
  });
}
