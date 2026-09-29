import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 应用内检测更新：按顺序查 1) Gitee Releases 2) 自建更新服务器。
/// 两边都没有新版本才提示「已是最新」。
///
/// 发新版：在仓库根目录跑 `pwsh scripts/release.ps1 -Version 1.0.9`，
/// 脚本会改版本号、构建 APK、在 Gitee 建 Release 并上传 APK 附件。
///
/// 为什么不再用 GitHub：App 侧原先硬编码了一个细粒度 PAT 才能读私有仓库，
/// 令牌随 APK 分发、无法轮换。Gitee 仓库是公开的，`releases/latest`
/// 匿名即可读，客户端**不需要**任何凭据。

/// 更新信息（发现新版本时返回）。
class UpdateInfo {
  final String version;

  /// APK 下载地址。
  final String url;

  /// 更新说明，可为空。
  final String notes;

  /// 来源：'Gitee' 或 '服务器'。
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

/// Gitee 仓库名（owner/repo）。留空 = 跳过 Gitee 检查。
const String kGiteeRepo = 'xuanduckl/danmaku';

/// 自建更新服务地址。留空 = 跳过该源。
/// 约定返回 JSON：{"version":"1.0.9","url":"https://.../x.apk","notes":"说明"}
const String kServerUpdateUrl = '';

/// 本 App 当前版本号（与 pubspec.yaml 的 version 保持一致）。
/// scripts/release.ps1 会在发版时同步改写这里。
const String kAppVersion = '1.1.0';

// ========================================================================

/// 检测更新：两个源都查一遍，收集所有有新版本的候选（Gitee 优先）。
/// 任一源失败不影响另一个；下载阶段再按候选顺序逐个尝试。
Future<UpdateCheckResult> checkForUpdate() async {
  var reached = false;
  final candidates = <UpdateInfo>[];

  // 1) Gitee Releases（公开仓库，匿名可读，不需要令牌）
  if (kGiteeRepo.isNotEmpty) {
    try {
      final r = await http
          .get(
            Uri.parse(
                'https://gitee.com/api/v5/repos/$kGiteeRepo/releases/latest'),
            headers: const {'User-Agent': 'Mozilla/5.0'},
          )
          .timeout(const Duration(seconds: 10));
      // 只有真的拿到 2xx 才算「源连通」，否则测速失败会被误报成「已是最新」。
      if (r.statusCode == 200) {
        reached = true;
        final j = jsonDecode(r.body);
        if (j is Map<String, dynamic>) {
          final tag = '${j['tag_name'] ?? ''}';
          final ver = tag.startsWith('v') || tag.startsWith('V')
              ? tag.substring(1)
              : tag;
          final apkUrl = _pickApkAsset(j['assets']);
          if (ver.isNotEmpty && apkUrl.isNotEmpty && isNewer(ver)) {
            candidates.add(UpdateInfo(
              version: ver,
              url: apkUrl,
              notes: '${j['body'] ?? ''}'.trim(),
              source: 'Gitee',
            ));
          }
        }
      } else {
        debugPrint('[update] Gitee 返回 HTTP ${r.statusCode}: '
            '${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
      }
    } catch (e) {
      debugPrint('[update] Gitee 检测失败: $e');
    }
  }

  // 2) 自建更新服务器（未配置时跳过）
  if (kServerUpdateUrl.isNotEmpty) {
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
    } catch (e) {
      debugPrint('[update] 更新服务器检测失败: $e');
    }
  }

  return UpdateCheckResult(candidates: candidates, reached: reached);
}

/// 从 Release 的 assets 里挑出 APK 下载地址。
///
/// Gitee 的 `assets` 除了我们上传的附件，还会自动带上 tag 的源码包
/// （`v1.0.9.zip` / `v1.0.9.tar.gz`），所以不能随便取第一个 ——
/// 必须精确挑 `.apk`。命名优先匹配 `danmaku-<tag>.apk`，
/// 取不到再退回「任意 .apk」。
String _pickApkAsset(Object? assets) {
  if (assets is! List) return '';
  String? fallback;
  for (final a in assets) {
    if (a is! Map) continue;
    final name = '${a['name'] ?? ''}';
    final url = '${a['browser_download_url'] ?? a['download_url'] ?? ''}';
    if (url.isEmpty || !name.toLowerCase().endsWith('.apk')) continue;
    if (name.startsWith('danmaku-')) return url;
    fallback ??= url;
  }
  return fallback ?? '';
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
  // Gitee 附件直链是公开的，不需要任何凭据。
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(info.url))..headers.addAll(headers);
    final resp = await client.send(req).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw Exception('下载失败（HTTP ${resp.statusCode}）');
    }
    final total = resp.contentLength ?? 0;
    var received = 0;
    final sink = partFile.openWrite();
    try {
      // 数据流空转 10 秒即超时报错 → 上层自动换源重试。
      // （只给「建立连接」设超时的话，源挂起时会永远卡在 0%。）
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 10))) {
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
    // 服务端没给 Content-Length 时（分块传输），至少卡一个体积下限：
    // 完整 APK 有几十 MB，明显过小的文件一定是被截断的。
    if (total == 0 && received < _minApkBytes) {
      throw Exception('下载文件过小，可能被截断（$received 字节）');
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

/// APK 的最小合理体积。低于它说明下载被截断（正常包 20MB 以上）。
const int _minApkBytes = 5 * 1024 * 1024;

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
