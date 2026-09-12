import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 应用内检测更新：按顺序查 1) GitHub Releases 2) 自建更新服务器。
/// 两边都没有新版本才提示「已是最新」。
///
/// 发新版的操作：
///   1. 改 pubspec.yaml 的 version，并同步改下面 [kAppVersion]；
///   2. GitHub：建仓库后把 `owner/repo` 填到 [kGithubRepo]，发一个 Release
///      （tag 形如 v1.0.1，附件里放 .apk）；
///   3. 自建服务器：在 [kServerUpdateUrl] 放一个 JSON：
///      {"version":"1.0.1","url":"https://.../app-release.apk","notes":"更新说明"}

/// 更新信息（发现新版本时返回）。
class UpdateInfo {
  final String version;

  /// APK 下载地址（交给系统浏览器打开，手动下载安装）。
  final String url;

  /// 更新说明，可为空。
  final String notes;

  /// 来源：'GitHub' 或 '服务器'。
  final String source;

  const UpdateInfo({
    required this.version,
    required this.url,
    this.notes = '',
    required this.source,
  });
}

/// 检测结果：update 为 null 时看 reached 判断是「已是最新」还是「网络不通」。
class UpdateCheckResult {
  final UpdateInfo? update;

  /// 是否至少有一个更新源连通（否则视为网络失败）。
  final bool reached;

  const UpdateCheckResult({required this.update, required this.reached});
}

// ======================= 发布配置（发新版时改这里） =======================

/// GitHub 仓库名（owner/repo）。留空 = 跳过 GitHub 检查。
const String kGithubRepo = 'XuanDuOwO/danmaku-space';

/// GitHub 访问令牌：仓库是私有的，Releases API 必须带令牌才能读。
/// 注意：令牌只放在这个私有仓库里，仓库转公开前必须先撤销它。
const String kGithubToken =
    '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';

/// 自建更新服务地址。
const String kServerUpdateUrl = 'http://47.102.106.125:18888/update/latest';

/// 本 App 当前版本号（与 pubspec.yaml 的 version 保持一致）。
const String kAppVersion = '1.0.1';

// ========================================================================

/// 检测更新：GitHub 优先，其次自建服务器。
Future<UpdateCheckResult> checkForUpdate() async {
  var reached = false;

  // 1) GitHub Releases（私有仓库需带令牌）
  if (kGithubRepo.isNotEmpty) {
    try {
      final r = await http
          .get(
            Uri.parse(
                'https://api.github.com/repos/$kGithubRepo/releases/latest'),
            headers: {
              'User-Agent': 'Mozilla/5.0',
              if (kGithubToken.isNotEmpty) 'Authorization': 'Bearer $kGithubToken',
            },
          )
          .timeout(const Duration(seconds: 10));
      reached = true;
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map<String, dynamic>) {
          final tag = '${j['tag_name'] ?? ''}';
          final ver = tag.startsWith('v') || tag.startsWith('V')
              ? tag.substring(1)
              : tag;
          var apkUrl = '';
          final assets = (j['assets'] as List<dynamic>?) ?? const [];
          for (final a in assets) {
            if (a is Map<String, dynamic> &&
                '${a['name'] ?? ''}'.toLowerCase().endsWith('.apk')) {
              apkUrl = '${a['browser_download_url'] ?? ''}';
              break;
            }
          }
          if (ver.isNotEmpty && apkUrl.isNotEmpty && isNewer(ver)) {
            return UpdateCheckResult(
              reached: true,
              update: UpdateInfo(
                version: ver,
                url: apkUrl,
                notes: '${j['body'] ?? ''}'.trim(),
                source: 'GitHub',
              ),
            );
          }
        }
      }
    } catch (_) {
      // GitHub 不通（网络/仓库未建）→ 继续查服务器
    }
  }

  // 2) 自建更新服务器
  try {
    final r2 = await http
        .get(Uri.parse(kServerUpdateUrl),
            headers: const {'User-Agent': 'Mozilla/5.0'})
        .timeout(const Duration(seconds: 10));
    if (r2.statusCode == 200) {
      reached = true;
      final j = jsonDecode(r2.body);
      if (j is Map<String, dynamic>) {
        final ver = '${j['version'] ?? ''}'.trim();
        final url = '${j['url'] ?? ''}'.trim();
        if (ver.isNotEmpty && url.isNotEmpty && isNewer(ver)) {
          return UpdateCheckResult(
            reached: true,
            update: UpdateInfo(
              version: ver,
              url: url,
              notes: '${j['notes'] ?? ''}'.trim(),
              source: '服务器',
            ),
          );
        }
      }
    }
  } catch (_) {
    // 服务器不通
  }

  return UpdateCheckResult(update: null, reached: reached);
}

/// 语义化比较：remote 是否比 kAppVersion 新（按数值逐段比较，如 1.2.10 > 1.2.9）。
bool isNewer(String remote, [String local = kAppVersion]) {
  final a = _verParts(remote);
  final b = _verParts(local);
  for (var i = 0; i < a.length; i++) {
    if (i >= b.length) return a[i] > 0;
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

List<int> _verParts(String v) {
  final clean = v.trim().replaceFirst(RegExp(r'^[vV]\s*'), '');
  final m = RegExp(r'\d+(?:\.\d+)*').firstMatch(clean);
  final s = m?.group(0) ?? '0';
  return s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
}

// ---------------------------------------------------------------- 打开浏览器

const MethodChannel _openUrlChannel =
    MethodChannel('cn.local.bili_live_relay/open_url');

/// 用系统浏览器打开下载页（手动更新：下载 APK → 安装）。
Future<void> openInBrowser(String url) async {
  if (url.isEmpty) return;
  try {
    await _openUrlChannel.invokeMethod('openUrl', {'url': url});
  } catch (_) {
    // 打不开就退回复制链接，由用户自己粘贴到浏览器。
    await Clipboard.setData(ClipboardData(text: url));
  }
}
