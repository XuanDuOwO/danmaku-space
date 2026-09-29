import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_live_relay/core/store.dart';

/// 亮屏保活是**粘性**开关：打开后一直保持，只有用户手动关闭才解除。
/// 这条语义靠持久化实现，所以这里盯的是 Store 的读写。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认是关闭的', () async {
    expect(await Store.loadKeepScreenOn(), isFalse);
  });

  test('打开后能读回来（跨"重启"仍在）', () async {
    await Store.saveKeepScreenOn(true);
    expect(await Store.loadKeepScreenOn(), isTrue);

    // 模拟重启：只清内存缓存，prefs 里的值仍在
    SharedPreferences.setMockInitialValues({
      'keep_screen_on': true,
    });
    expect(await Store.loadKeepScreenOn(), isTrue);
  });

  test('手动关闭后不再恢复', () async {
    await Store.saveKeepScreenOn(true);
    await Store.saveKeepScreenOn(false);
    expect(await Store.loadKeepScreenOn(), isFalse);
  });

  test('和其它设置互不干扰', () async {
    await Store.saveKeepScreenOn(true);
    await Store.saveRoomId(8385390);
    expect(await Store.loadKeepScreenOn(), isTrue);
    expect(await Store.loadRoomId(), 8385390);
  });

  test('清理旧弹幕记录时不会误删保活开关', () async {
    await Store.saveKeepScreenOn(true);
    SharedPreferences.setMockInitialValues({
      'keep_screen_on': true,
      'dlog_2026-09-12': '[]',
      'log_seq': 42,
      'etab_123': '{"[花]":"https://x"}',
    });
    await Store.purgeLegacyLogs();

    expect(await Store.loadKeepScreenOn(), isTrue);
    final p = await SharedPreferences.getInstance();
    expect(p.getKeys().any((k) => k.startsWith('dlog_')), isFalse);
    expect(p.getInt('log_seq'), isNull);
    // 表情表不属于"弹幕记录"，要保留
    expect(p.getString('etab_123'), isNotNull);
  });
}
