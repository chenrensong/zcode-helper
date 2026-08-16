import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/account_models.dart';
import '../core/bigmodel_profile.dart';
import '../core/crypto.dart';
import '../core/paths.dart';
import '../platform/zcode_bridge.dart';
import 'app_log.dart';
import 'fs_utils.dart';
import 'tokens.dart';

class SwitchAborted implements Exception {
  @override
  String toString() => '切换已取消';
}

class SwitchError implements Exception {
  SwitchError(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef DeriveCodingPlanKey = Future<String?> Function(String accessToken);
typedef PhaseHandler = void Function(SwitchPhase phase, String message);

/// 账号切换控制器：备份 → 原子写入 → 清缓存 → 重启 ZCode。
class SwitchController {
  SwitchController({
    required this.paths,
    required this.platform,
    String? secret,
    this.deriveCodingPlanKey,
    this.autoWaitMs = 10000,
    this.pollMs = 1200,
  }) {
    _secret = secret;
  }

  final AppPaths paths;
  final ZCodePlatform platform;
  final DeriveCodingPlanKey? deriveCodingPlanKey;
  final int autoWaitMs;
  final int pollMs;
  String? _secret;

  Future<SwitchResult> switchTo({
    required Snapshot rawSnapshot,
    String? snapshotId,
    PhaseHandler? onPhase,
    bool Function()? isCancelled,
  }) async {
    void phase(SwitchPhase p, String msg) => onPhase?.call(p, msg);
    phase(SwitchPhase.preparing, '读取目标快照…');

    // 1. provider 检测
    final provider = await detectProviderFromSnapshot(rawSnapshot, secret: _secret) ?? 'zai';
    appLog('switch', 'start provider=$provider snapshot=${snapshotId ?? '-'}');

    // 2. BigModel 原生 profile 标准化（纯内存）
    phase(SwitchPhase.normalizing, '标准化账号资料（$provider）…');
    var target = await _normalizeBigModelSnapshotProfile(rawSnapshot, provider);

    // 3. config provider 段修复 + coding-plan key 派生
    phase(SwitchPhase.preparing, '修复 provider 配置…');
    target = await _fixConfig(target, provider);

    // 4. setting 内容构建（跟随检测到的 provider）
    final settingContent = _buildSettingContent(provider);

    // 5. 运行检测与退出（对齐 Electron switchTo：只杀主客户端 ZCode；
    //    实例客户端 ZCode [xxx] 使用隔离 HOME，不读共享登录态，不杀，
    //    否则用户实例被误关且无法恢复。超时则中止切换，避免旧进程
    //    未死又启动新客户端导致双开。）
    var ran = false;
    var running = await platform.runningZcodeProcesses();
    final plainMains = running.where((proc) => (proc.name ?? '') == 'ZCode').toList();
    if (plainMains.isNotEmpty) {
      ran = true;
      phase(SwitchPhase.terminating, '正在安全结束 ZCode…');
      final pids = plainMains.map((proc) => proc.pid).where((pid) => pid > 0).toList();
      final results = await platform.terminatePids(pids);
      final failed = results.entries.where((e) => !e.value).toList();
      if (failed.isNotEmpty || results.isEmpty) {
        // 兜底逐 pid 终止。绝不能按进程名批量杀（pkill -x ZCode /
        // taskkill /IM ZCode.exe）：多开实例与主客户端是同一个二进制、
        // 同名进程，仅应用显示名不同，按名杀会误杀全部多开实例。
        final fallbackPids = results.isEmpty
            ? pids
            : failed.map((e) => e.key).toList();
        for (final pid in fallbackPids.toSet()) {
          try {
            Process.killPid(pid, ProcessSignal.sigterm);
          } catch (_) {}
        }
      }
      final deadline = DateTime.now().add(Duration(milliseconds: autoWaitMs));
      var alivePids = const <int>{};
      while (DateTime.now().isBefore(deadline)) {
        alivePids = (await platform.runningZcodeProcesses())
            .where((proc) => (proc.name ?? '') == 'ZCode' && proc.pid > 0)
            .map((proc) => proc.pid)
            .toSet();
        if (alivePids.isEmpty) break;
        await Future<void>.delayed(Duration(milliseconds: pollMs));
      }
      if (alivePids.isNotEmpty) {
        appLog('switch', 'kill timeout, aborted: $alivePids');
        throw SwitchError('关闭 ZCode 超时，已取消切换（避免登录态损坏与双开）');
      }
    }

    // 6. 备份当前登录态（setting.json 也入备份：切换会改写其 provider
    //    family 域，回滚若不还原会留下凭据与 provider 不一致的失效组合）
    phase(SwitchPhase.writing, '备份当前登录态…');
    final backupDir = Directory(paths.backupDir)..createSync(recursive: true);
    for (final entry in [
      (paths.credentialsFile, 'credentials.json'),
      (paths.configFile, 'config.json'),
      (paths.settingFile, 'setting.json'),
    ]) {
      if (File(entry.$1).existsSync()) {
        File(entry.$1).copySync('${backupDir.path}/${entry.$2}');
      }
    }

    // 7. 原子写入
    phase(SwitchPhase.writing, '写入目标账号…');
    atomicWrite(paths.credentialsFile, target.credentials);
    atomicWrite(paths.configFile, target.config);
    if (settingContent != null) {
      try {
        atomicWrite(paths.settingFile, settingContent);
      } catch (_) {}
    }

    // 8. 清理 coding-plan 缓存
    phase(SwitchPhase.clearingCache, '清理缓存…');
    try {
      for (final target in [
        paths.codingPlanCacheFile,
        p.join(paths.zcodeV2Dir, 'coding-cache'),
        p.join(paths.zcodeV2Dir, 'caching'),
      ]) {
        final file = File(target);
        if (file.existsSync()) file.deleteSync();
        final dir = Directory(target);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    } catch (_) {}

    // 9. 启动
    phase(SwitchPhase.launching, '启动 ZCode…');
    final restarted = await platform.launchZCode(paths.findZCodeExe());
    appLog('switch', 'done restarted=$restarted');
    phase(SwitchPhase.done, '切换完成');
    return SwitchResult(
      snapshotId: snapshotId ?? '',
      mode: ran ? 'auto-restart' : 'cold-start',
      restarted: restarted,
      wasRunning: ran,
    );
  }

  /// BigModel 旧版通用资料 → 原生 cached-profile（含重新加密）。
  Future<Snapshot> _normalizeBigModelSnapshotProfile(Snapshot s, String provider) async {
    if (provider != 'bigmodel') return s;
    try {
      final creds = jsonDecode(s.credentials) as Map<String, dynamic>;
      final key = 'oauth:bigmodel:user_info';
      final raw = creds[key];
      if (raw == null) return s;
      final plain = raw is String && isEncrypted(raw)
          ? await decrypt(raw, secret: _secret)
          : raw.toString();
      final profile = jsonDecode(plain);
      if (profile is! Map) return s;
      if (isNativeBigModelUserProfile(profile)) return s;
      final normalized = normalizeBigModelUserProfile(profile);
      creds[key] = await encrypt(jsonEncode(normalized), secret: _secret);
      return Snapshot(credentials: jsonEncode(creds), config: s.config);
    } catch (e) {
      return s;
    }
  }

  /// 修复 `config.json` 的 provider 段；BigModel 时派生 coding-plan key。
  Future<Snapshot> _fixConfig(Snapshot s, String provider) async {
    try {
      final config = jsonDecode(s.config);
      if (config is! Map || config['provider'] is! Map) return s;
      final cfg = Map<String, dynamic>.from(config);
      final rawProvidersBefore = cfg['provider'];
      final providersBefore = rawProvidersBefore is Map
          ? Map<String, dynamic>.from(rawProvidersBefore)
          : <String, dynamic>{};

      String? apiKey;
      final spec = kProviders[provider] ?? kProviders['zai']!;
      for (final entry in spec.entries) {
        if (entry.value.withApiKey != true) continue;
        final p = providersBefore[entry.key];
        final options = p is Map ? p['options'] : null;
        if (options is Map) {
          final apiKeyValue = options['apiKey'];
          if (apiKeyValue is String) {
            apiKey = apiKeyValue;
            break;
          }
        }
      }
      updateConfigProviders(cfg, provider, apiKey);
      final rawProviders = cfg['provider'];
      final providers = rawProviders is Map ? Map<String, dynamic>.from(rawProviders) : <String, dynamic>{};

      if (provider == 'bigmodel') {
        try {
          final slot = providers['builtin:bigmodel-coding-plan'];
          if (slot is Map) {
            final slotOptions = slot['options'];
            final options = slotOptions is Map
                ? Map<String, dynamic>.from(slotOptions)
                : <String, dynamic>{};
            final apiKeyValue = options['apiKey'];
            final current = apiKeyValue is String ? apiKeyValue : '';
            if ((current.isEmpty || current.startsWith('eyJ')) && deriveCodingPlanKey != null) {
              final creds = jsonDecode(s.credentials) as Map<String, dynamic>;
              final at = await safeDecrypt(creds['oauth:bigmodel:access_token'], secret: _secret);
              if (at != null) {
                final derived = await deriveCodingPlanKey!(at);
                if (derived != null) options['apiKey'] = derived;
              }
            }
            slot['options'] = options;
          }
        } catch (_) {}
        cfg['provider'] = providers;
      }
      return Snapshot(credentials: s.credentials, config: const JsonEncoder().convert(cfg));
    } catch (e) {
      return s;
    }
  }

  /// setting.json 的 providerFamilyDomain 必须跟随目标账号的 provider
  /// （与 Electron switchTo 一致；硬编码 zai 会让 BigModel 账号登录态失效）。
  String? _buildSettingContent(String provider) {
    try {
      final setting = readJsonIfExists(paths.settingFile);
      if (setting.isEmpty) return null;
      updateSettingProviderFamily(setting, provider);
      return const JsonEncoder.withIndent('  ').convert(setting);
    } catch (_) {
      return null;
    }
  }

  /// 回滚到最近一次备份（.last）。setting.json 若在备份中则一并还原，
  /// 避免回滚后 provider family 与凭据错配导致登录态失效。
  Map<String, dynamic> rollbackToLast({PhaseHandler? onPhase}) {
    final backupDir = Directory(paths.backupDir);
    final creds = File('${backupDir.path}/credentials.json');
    final cfg = File('${backupDir.path}/config.json');
    if (!creds.existsSync() || !cfg.existsSync()) {
      throw SwitchError('没有可回滚的备份');
    }
    onPhase?.call(SwitchPhase.writing, '从备份恢复…');
    atomicWrite(paths.credentialsFile, creds.readAsStringSync());
    atomicWrite(paths.configFile, cfg.readAsStringSync());
    final setting = File('${backupDir.path}/setting.json');
    if (setting.existsSync()) {
      atomicWrite(paths.settingFile, setting.readAsStringSync());
    }
    return {'backupDir': backupDir.path, 'restoredAt': DateTime.now().millisecondsSinceEpoch};
  }
}
