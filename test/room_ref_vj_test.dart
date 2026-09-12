import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/room_ref.dart';

void main() {
  test('新反馈的链接：AL vs IG（赛事活动页形态）', () async {
    final r = await parseRoomInput(
        '【【直播】AL vs IG-bilibili直播】 https://b23.tv/Vj1RL4K');
    // ignore: avoid_print
    print('result: $r');
    expect(r, 7734200);
  });
}
