import 'package:flutter/material.dart';

import 'blive/api.dart';
import 'login_page.dart';
import 'shell.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '弹幕空间',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4D9FFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const Gate(),
    );
  }
}

/// 启动闸门：**必须先扫码登录才能进入首页**。
/// 校验本地登录态；无效/过期则清掉并强制回到扫码页。
class Gate extends StatefulWidget {
  const Gate({super.key});

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  bool _checking = true;
  bool _loggedIn = false;
  String _name = '';
  String _face = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (mounted) setState(() => _checking = true);
    final cookie = await Store.loadCookie();
    var ok = false;
    var name = '';
    var face = '';
    if (cookie.isNotEmpty) {
      final api = BilibiliApi(cookie: cookie);
      try {
        await api.ensureIdentity();
        final p = await api.getProfile();
        ok = p.isLogin;
        name = p.name;
        face = p.face;
      } catch (_) {
        ok = false;
      } finally {
        api.dispose();
      }
    }
    if (!ok) await Store.clearCookie();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _loggedIn = ok;
      _name = name;
      _face = face;
    });
  }

  /// 退出登录：清掉本地票据并回到扫码页。
  /// 由「设置」模块触发，经 AppShell 回调上来。
  Future<void> _logout() async {
    await Store.clearCookie();
    if (!mounted) return;
    setState(() {
      _loggedIn = false;
      _name = '';
      _face = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_loggedIn) {
      return LoginPage(
        onLoggedIn: (p) => setState(() {
          _loggedIn = true;
          _name = p.name;
          _face = p.face;
        }),
      );
    }
    return AppShell(
      loginName: _name,
      loginFace: _face,
      onLogout: () => _logout(),
    );
  }
}
