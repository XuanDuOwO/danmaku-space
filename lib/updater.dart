import 'dart:convert';
import 'dart:io';

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

/// 检测结果：candidates 是**所有**有新版本的源（按优先级排好序），
/// 下载时逐个尝试，任一成功即用 —— 两个源完全等价、自动互备。
class UpdateCheckResult {
  final List<UpdateInfo> candidates;

  /// 是否至少有一个更新源连通（否则视为网络失败）。
  final bool reached;

  const UpdateCheckResult({required this.candidates, required this.reached});

  UpdateInfo? get update => candidates.isEmpty ? null : candidates.first;
}

// ======================= 发布配置（发新版时改这里） =======================

/// GitHub 仓库名（owner/repo）。留空 = 跳过 GitHub 检查。
const String kGithubRepo = 'XuanDuOwO/danmaku-space';

/// GitHub 访问令牌：仓库是私有的，Releases API 必须带令牌才能读。
/// 注意：令牌只放在这个私有仓库里，仓库转公开前必须先撤销它。
const String kGithubToken =
    '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';

/// 自建更新服务地址（qyauth 实际监听 18080）。
const String kServerUpdateUrl = 'http://47.102.106.125:18080/update/latest';

/// 本 App 当前版本号（与 pubspec.yaml 的 version 保持一致）。
const String kAppVersion = '1.0.4';

// ========================================================================

/// 检测更新：两个源都查一遍，收集所有有新版本的候选（GitHub 优先）。
/// 任一源失败不影响另一个；下载阶段再按候选顺序逐个尝试。
Future<UpdateCheckResult> checkForUpdate() async {
  var reached = false;
  final candidates = <UpdateInfo>[];

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
              // 用 API 资产地址而非浏览器地址：私有仓库的浏览器链接
              // 不带登录态会 404，API 地址配合 Bearer 令牌可直接下载
              // （Accept: application/octet-stream 时返回文件流）。
              apkUrl = '${a['url'] ?? ''}';
              break;
            }
          }
          if (ver.isNotEmpty && apkUrl.isNotEmpty && isNewer(ver)) {
            candidates.add(UpdateInfo(
              version: ver,
              url: apkUrl,
              notes: '${j['body'] ?? ''}'.trim(),
              source: 'GitHub',
            ));
          }
        }
      }
    } catch (_) {
      // GitHub 不通（网络/仓库未建）→ 用服务器
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
        final dup = candidates.any((c) => c.version == ver && c.url == url);
        if (ver.isNotEmpty && url.isNotEmpty && !dup && isNewer(ver)) {
          candidates.add(UpdateInfo(
            version: ver,
            url: url,
            notes: '${j['notes'] ?? ''}'.trim(),
            source: '服务器',
          ));
        }
      }
    }
  } catch (_) {
    // 服务器不通
  }

  return UpdateCheckResult(candidates: candidates, reached: reached);
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

/// 用系统浏览器打开下载页（备用手段：应用内下载失败时可退回）。
Future<void> openInBrowser(String url) async {
  if (url.isEmpty) return;
  try {
    await _openUrlChannel.invokeMethod('openUrl', {'url': url});
  } catch (_) {
    // 打不开就退回复制链接，由用户自己粘贴到浏览器。
    await Clipboard.setData(ClipboardData(text: url));
  }
}

/// 应用专属更新目录（getExternalFilesDir/update），无需存储权限。
Future<String> _updateDir() async {
  return await _openUrlChannel.invokeMethod<String>('getUpdateDir') ?? '';
}

/// 应用内下载 APK 到更新目录，[onProgress] 回调 0~1。
/// 下载完成后返回本地文件路径，交给 [installApk] 拉起安装。
///
/// 可靠性设计：
///   - 先写 `*.part` 半成品文件，下载完成校验后才改名成正式文件 ——
///     中途退出/断网留下的残件绝不会被当成完整包去安装；
///   - 数据流 5 秒无新数据即超时中断（上层自动换下一个源重试）——
///     只对"建立连接"设超时的话，源挂起时会永远卡在 0%。
Future<String> downloadApk(
  UpdateInfo info, {
  void Function(double progress)? onProgress,
}) async {
  final dir = await _updateDir();
  if (dir.isEmpty) throw Exception('无法获取更新目录');
  final file = File('$dir/danmaku-space-${info.version}.apk');
  final partFile = File('${file.path}.part');
  // 只信任下载完成后改名的完整文件；<1MB 的异常文件直接重下
  if (await file.exists()) {
    if (await file.length() > 1024 * 1024) return file.path;
    await file.delete();
  }
  if (await partFile.exists()) await partFile.delete();

  final headers = <String, String>{'User-Agent': 'Mozilla/5.0'};
  // 私有 GitHub 仓库的资产走 API 地址 + 令牌 + octet-stream
  if (info.url.contains('api.github.com') && kGithubToken.isNotEmpty) {
    headers['Authorization'] = 'Bearer $kGithubToken';
    headers['Accept'] = 'application/octet-stream';
  }
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(info.url))..headers.addAll(headers);
    final resp = await client.send(req).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw Exception('下载失败（HTTP ${resp.statusCode}）');
    }
    final total = resp.contentLength ?? 0;
    var received = 0;
    final sink = partFile.openWrite();
    try {
      // 数据流空转 20 秒即超时报错 → 上层自动换源重试
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 5))) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close().catchError((_) {});
      rethrow;
    }
    if (total > 0 && received != total) {
      throw Exception('下载不完整（$received / $total）');
    }
    await partFile.rename(file.path); // 完整才转正
    onProgress?.call(1.0);
    return file.path;
  } catch (_) {
    // 下载中断就删掉半成品，避免残留
    if (await partFile.exists()) await partFile.delete();
    rethrow;
  } finally {
    client.close();
  }
}

/// 拉起系统安装器安装已下载的 APK。
Future<void> installApk(String path) async {
  await _openUrlChannel.invokeMethod('installApk', {'path': path});
}

/// 清空更新目录里的安装包（无论安装成败都应调用）。
Future<void> cleanUpdateApks() async {
  try {
    await _openUrlChannel.invokeMethod('cleanUpdateApks');
  } catch (_) {}
}
