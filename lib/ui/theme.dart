import 'package:flutter/material.dart';

/// 全局配色：**纯黑 OLED 风格**。
///
/// 为什么刻意用纯黑而不是常见的 #0E1116 深灰：
///   本 App 支持「亮屏保活 + 全屏弹幕」长时间常亮挂机，
///   长时间静止的亮色像素在 OLED 上会烧屏（残影）。
///   把大面积底色做成真黑（#000000），OLED 那些像素直接不发光，
///   既省电又几乎不会留下残影；只有文字与图标是亮的，
///   而它们的位置与内容一直在变，不容易烧出固定图案。
///
/// 因此约定：
///   - 页面/卡片背景一律用 [background] 或 [surface]（都是纯黑）；
///   - 需要区分层次时用 1px 描边（[border]）而不是填充色；
///   - 强调色只用在文字、小图标、细描边上，不做大面积色块。
class AppColors {
  const AppColors._();

  /// 页面底色。纯黑，OLED 不发光。
  static const Color background = Color(0xFF000000);

  /// 卡片 / 列表 / 顶栏底色。同样是纯黑，靠描边分层。
  static const Color surface = Color(0xFF000000);

  /// 需要略微区分「非内容区」时用（如日期分组头）。极暗，几乎不发光。
  static const Color surfaceDim = Color(0xFF060606);

  /// 选中态 / 强调块的极暗底。
  static const Color surfaceHighlight = Color(0xFF0D0D0D);

  /// 分隔线。替代原来的填充式分层。
  static const Color border = Color(0xFF1C1C1C);

  /// 更弱的分隔线（列表行之间）。
  static const Color borderFaint = Color(0xFF141414);

  /// 主强调色（B站粉偏蓝改成的青蓝，夜间不刺眼）。
  static const Color primary = Color(0xFF4D9FFF);

  // ---- 语义色（只用于文字/图标，避免大面积填充） ----
  static const Color success = Color(0xFF3FB950);
  static const Color warning = Color(0xFFD29922);
  static const Color danger = Color(0xFFF85149);
  static const Color gift = Color(0xFFE3B341);
  static const Color guard = Color(0xFFA371F7);
  static const Color superchat = Color(0xFFF778BA);

  // ---- 文字 ----
  static const Color textPrimary = Color(0xFFE6EDF3);
  static const Color textSecondary = Color(0xFF8B949E);
  static const Color textFaint = Color(0xFF6E7681);

  /// 昵称色（弹幕行里的发送者）。
  static const Color userName = Color(0xFF85B7EB);
}

/// 组装 App 主题。
ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    secondary: AppColors.primary,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    outline: AppColors.textFaint,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    // 纯黑底：OLED 上不发光，长时间挂机不烧屏
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    dividerColor: AppColors.border,
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.surfaceHighlight,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          color: selected ? AppColors.primary : AppColors.textFaint,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? AppColors.primary : AppColors.textFaint,
        );
      }),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF0A0A0A),
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF161616),
      contentTextStyle: TextStyle(color: AppColors.textPrimary, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      tileColor: AppColors.surface,
      iconColor: AppColors.textSecondary,
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF080808),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.primary),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.primary,
      unselectedLabelColor: AppColors.textFaint,
      indicatorColor: AppColors.primary,
      dividerColor: AppColors.border,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Color(0xFF0A0A0A),
      surfaceTintColor: Colors.transparent,
    ),
  );
}
