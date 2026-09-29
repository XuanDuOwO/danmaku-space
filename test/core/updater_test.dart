import 'package:flutter_test/flutter_test.dart';

import 'package:bili_live_relay/core/updater.dart';

void main() {
  group('isNewer', () {
    test('按段数值比较，不是字符串比较', () {
      // 字符串比较会认为 "1.2.9" > "1.2.10"，必须逐段转数字
      expect(isNewer('1.2.10', '1.2.9'), isTrue);
      expect(isNewer('1.2.9', '1.2.10'), isFalse);
      expect(isNewer('1.10.0', '1.9.9'), isTrue);
    });

    test('相同版本不算新', () {
      expect(isNewer('1.1.0', '1.1.0'), isFalse);
      expect(isNewer('v1.1.0', '1.1.0'), isFalse);
    });

    test('对方段数更多且多出来的段非零时算新', () {
      expect(isNewer('1.1.0.1', '1.1.0'), isTrue);
      expect(isNewer('1.1.0.0', '1.1.0'), isFalse);
    });

    test('能识别 v 前缀，也能容忍脏字符串', () {
      expect(isNewer('v1.2.0', '1.1.0'), isTrue);
      expect(isNewer('V1.2.0', '1.1.0'), isTrue);
      expect(isNewer('1.1.0-beta', '1.1.0'), isFalse);
      expect(isNewer('', '1.1.0'), isFalse);
    });

    test('默认与 kAppVersion 比较', () {
      // 当前版本比它自己新不了
      expect(isNewer(kAppVersion), isFalse);
    });
  });

  group('发布源配置', () {
    test('Gitee 与 GitHub 两个源都已配置（用户要求双源）', () {
      expect(kGiteeRepo, isNotEmpty);
      expect(kGithubRepo, isNotEmpty);
      // owner/repo 形式
      expect(kGiteeRepo.split('/').length, 2);
      expect(kGithubRepo.split('/').length, 2);
    });

    test('kAppVersion 是纯 x.y.z（发版脚本会同步它）', () {
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(kAppVersion), isTrue,
          reason: 'kAppVersion 应与 pubspec.yaml 的 version 一致，实际为 $kAppVersion');
    });
  });

  group('UpdateCheckResult', () {
    test('update 取优先级最高的候选（列表顺序即优先级）', () {
      const r = UpdateCheckResult(
        reached: true,
        candidates: [
          UpdateInfo(version: '1.2.0', url: 'https://a/x.apk', source: 'Gitee'),
          UpdateInfo(version: '1.2.0', url: 'https://b/x.apk', source: 'GitHub'),
        ],
      );
      expect(r.update!.source, 'Gitee');
    });

    test('没有候选时 update 为 null', () {
      const r = UpdateCheckResult(reached: true, candidates: []);
      expect(r.update, isNull);
    });
  });
}
