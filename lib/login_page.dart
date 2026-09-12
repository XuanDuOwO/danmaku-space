import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'blive/api.dart';
import 'store.dart';

/// 扫码登录页：**启动后必须扫码登录才能进入**（由 main.dart 的 Gate 控制）。
/// 只支持扫码、不做账号密码输入，避免密码经手本 App。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.onLoggedIn});

  /// 登录成功回调，带回完整登录资料（昵称 + 头像）。
  final ValueChanged<Profile>? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  QrLoginSession? _session;
  String? _url;
  String _tip = '正在生成二维码…';
  bool _done = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _tip = '正在生成二维码…';
      _done = false;
      _url = null;
    });
    _session?.dispose();
    final session = QrLoginSession();
    _session = session;
    try {
      final url = await session.generate();
      if (!mounted) return;
      setState(() {
        _url = url;
        _tip = '请用手机 B站 App 扫码';
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _tip = '二维码生成失败：$e');
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    final session = _session;
    if (session == null || _done) return;
    try {
      final (code, message, _) = await session.poll();
      if (!mounted) return;
      setState(() => _tip = message);
      if (code == 0) {
        _timer?.cancel();
        _done = true;
        final api = BilibiliApi(cookie: session.cookie);
        Profile profile;
        try {
          await api.ensureIdentity();
          profile = await api.getProfile();
        } catch (_) {
          profile = const Profile(isLogin: false);
        } finally {
          api.dispose();
        }
        if (profile.isLogin) {
          await Store.saveCookie(session.cookie);
          if (!mounted) return;
          setState(() => _tip = '登录成功：${profile.name}');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (!mounted) return;
          widget.onLoggedIn?.call(profile);
        } else {
          setState(() => _tip = '拿到的登录态无效，请重新扫码');
          _done = false;
        }
      } else if (code == 86038) {
        // 二维码失效
        _timer?.cancel();
        setState(() => _tip = '二维码已失效，请点下方刷新');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _tip = '轮询出错：$e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('B站扫码登录'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              if (_url != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: _url!,
                    version: QrVersions.auto,
                    size: 230,
                    backgroundColor: Colors.white,
                  ),
                )
              else
                const SizedBox(
                  width: 230,
                  height: 230,
                  child: Center(child: CircularProgressIndicator()),
                ),
              const SizedBox(height: 18),
              Text(
                _tip,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _done ? Colors.green : cs.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.tonal(
                onPressed: _done ? null : _generate,
                child: const Text('刷新二维码'),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF11161D),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF222831)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield_outlined, size: 15, color: cs.primary),
                        const SizedBox(width: 6),
                        Text(
                          '为什么只能用扫码登录？',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '· 本应用不提供账号密码输入，密码永远不会经过本应用，'
                      '也没有任何地方可以保存你的密码。\n'
                      '· 扫码由 B站官方服务端直接返回登录票据（Cookie），'
                      '与你在浏览器登录是同一种方式。\n'
                      '· 票据只保存在本机，不上传、不共享；'
                      '在 B站 App 里退出登录即可让它立即失效。\n'
                      '· 本应用只读弹幕所需的公开数据，不读取你的私信、'
                      '订单等隐私信息。',
                      style: TextStyle(
                          fontSize: 11.5, color: cs.outline, height: 1.75),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '登录后才能进入弹幕页（不带登录态时昵称会显示为 j***）',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: cs.outline, height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
