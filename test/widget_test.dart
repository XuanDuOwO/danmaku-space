import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_live_relay/main.dart';
import 'package:bili_live_relay/ui/pages/login_page.dart';

/// 启动闸门的冒烟测试。
///
/// 原来的模板测试断言「计数器」行为（`find.text('0')` + `Icons.add`），
/// 而本 App 根本没有计数器 —— 首页是 [Gate]：没登录时直接进入扫码页。
/// 那个测试从项目创建起就不可能通过，这里换成真正有意义的断言。
///
/// 注意：不能用 `pumpAndSettle`。扫码页在拿到二维码之前一直转菊花，
/// 而菊花是无限动画，永远「settle」不下来；只能用固定步长的 `pump`。
void main() {
  setUp(() {
    // Gate 会读本地登录票据；不 mock 的话 SharedPreferences 会抛
    // MissingPluginException。
    SharedPreferences.setMockInitialValues({});
  });

  /// 反复 pump 若干帧，让 Gate 的异步校验走完。
  /// 测试环境里 HTTP 会被 flutter_test 拦掉，扫码请求会很快失败。
  Future<void> settleGate(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('未登录时进入扫码登录页，而不是主界面', (tester) async {
    await tester.pumpWidget(const MyApp());
    // 首帧在等 Gate 校验登录态
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 校验完成（无票据）→ 必须落在 LoginPage
    await settleGate(tester);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('B站扫码登录'), findsOneWidget);
    expect(find.text('刷新二维码'), findsOneWidget);
  });

  testWidgets('扫码页不含账号密码输入框（安全承诺）', (tester) async {
    await tester.pumpWidget(const MyApp());
    await settleGate(tester);
    expect(find.byType(LoginPage), findsOneWidget);
    // 全页不应出现任何文本输入控件
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
  });
}
