import 'package:flutter/services.dart';

/// 亮屏保活：让屏幕在「弹幕空间」挂机时不要自动熄灭。
///
/// 实现走 Android 原生的 `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`
/// （见 `MainActivity.kt` 的 `setKeepScreenOn`），而不是引入第三方
/// wakelock 插件 —— 这个标志由窗口系统管理，**退出应用/Activity 销毁时
/// 自动失效**，不会出现「忘记释放导致一直不熄屏」的漏电问题。
///
/// 为什么不加 WAKE_LOCK 权限：`FLAG_KEEP_SCREEN_ON` 不需要任何权限，
/// 而 `PARTIAL_WAKE_LOCK` 需要 WAKE_LOCK 权限且必须手动释放，风险更大。
class ScreenKeeper {
  const ScreenKeeper._();

  static const MethodChannel _ch =
      MethodChannel('cn.local.bili_live_relay/open_url');

  static bool _on = false;

  /// 当前是否已开启亮屏保活。
  static bool get isOn => _on;

  /// 开关亮屏保活。失败（非 Android 平台 / 通道异常）时静默忽略，
  /// 并把内部状态回滚，避免 UI 显示「已开启」但实际没生效。
  static Future<bool> setEnabled(bool on) async {
    try {
      final r = await _ch.invokeMethod<bool>('setKeepScreenOn', {'on': on});
      _on = r ?? on;
    } catch (_) {
      _on = false;
    }
    return _on;
  }

  /// 退出应用 / 离开弹幕页时务必调用，避免屏幕永远不灭。
  static Future<void> release() => setEnabled(false);
}
