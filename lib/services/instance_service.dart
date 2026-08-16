import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/account_models.dart';
import '../core/crypto.dart';
import '../core/fingerprint.dart';
import '../core/paths.dart';
import '../platform/zcode_bridge.dart';
import 'account_store.dart';
import 'fs_utils.dart';

class InstanceService {
  InstanceService({
    required this.paths,
    required this.platform,
    AccountStore? store,
    String? secret,
  }) {
    _store = store;
    _secret = secret;
  }

  final AppPaths paths;
  final ZCodePlatform platform;
  AccountStore? _store;
  String? _secret;

  String metaFile(String id) => p.join(paths.instanceRoot(id), 'instance.json');

  /// 列出实例（受管 + 外部运行实例，含账号解析）。
  Future<List<RuntimeInstance>> list() async {
    final managed = _readManaged();
    final running = await platform.runningZcodeProcesses();
    var merged = mergeRuntimeInstances(managed, running);

    // 名称认领到的有效 pid 与元数据不一致时回写（stop 需要真实的应用 pid）
    for (final m in managed) {
      final fresh = merged.where((x) => x.id == m.id).firstOrNull;
      if (fresh != null && fresh.pid != null && fresh.pid != m.pid) {
        _writeMeta(fresh);
      }
    }

    final results = <RuntimeInstance>[];
    for (final instance in merged) {
      results.add(await _withAccount(instance));
    }
    return results;
  }

  List<RuntimeInstance> _readManaged() {
    try {
      final dir = Directory(paths.instancesDir);
      if (!dir.existsSync()) return const [];
      final entries = <RuntimeInstance>[];
      for (final sub in dir.listSync().whereType<Directory>()) {
        final meta = File(p.join(sub.path, 'instance.json'));
        if (!meta.existsSync()) continue;
        try {
          final json = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
          entries.add(RuntimeInstance(
            id: (json['id'] ?? 'inst').toString(),
            name: (json['name'] ?? 'ZCode').toString(),
            pid: json['pid'] as int?,
            bindAccountId: json['bindAccountId'] as String?,
            managed: true,
          ));
        } catch (_) {}
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  Future<void> ensureSetup() async {
    final dir = Directory(paths.instancesDir);
    if (dir.existsSync() && dir.listSync().isNotEmpty) return;
    dir.createSync(recursive: true);
    await create(name: 'ZCode #1');
  }

  /// 创建实例（实例名全局唯一，大小写不敏感——名称是多开进程的认领键）。
  Future<RuntimeInstance> create({String? name, String? bindAccountId}) async {
    _validateBindAccount(bindAccountId);
    final trimmed = (name ?? '').trim();
    if (trimmed.isNotEmpty) {
      final duplicated = _readManaged().any((i) => i.name.toLowerCase() == trimmed.toLowerCase());
      if (duplicated) throw StateError('实例名已存在：$trimmed（名称用于识别多开进程，不能重复）');
    }
    final id = 'inst-${Random.secure().nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0')}';
    final root = Directory(paths.instanceRoot(id));
    if (!root.existsSync()) root.createSync(recursive: true);
    Directory(paths.instanceDataRoot(id)).createSync(recursive: true);
    final instance = RuntimeInstance(
      id: id,
      name: trimmed.isEmpty ? 'ZCode #$id' : trimmed,
      pid: null,
      bindAccountId: bindAccountId,
      managed: true,
    );
    _writeMeta(instance);
    return instance;
  }

  void _validateBindAccount(String? bindAccountId) {
    if (bindAccountId == null) return;
    if (_store == null) throw StateError('缺少账号存储，无法绑定账号');
    try {
      _store!.load(bindAccountId);
    } catch (e) {
      throw StateError('绑定账号不存在: $bindAccountId');
    }
  }

  void _writeMeta(RuntimeInstance instance) {
    final map = {
      'id': instance.id,
      'name': instance.name,
      if (instance.pid != null) 'pid': instance.pid,
      if (instance.bindAccountId != null) 'bindAccountId': instance.bindAccountId,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    writeJsonPretty(metaFile(instance.id), map);
  }

  /// 启动实例。
  ///
  /// 流程：校验可执行文件 → 写入登录态与环境 → spawn → 短暂等待后校验进程存活。
  /// 若进程立即退出（典型原因：被正在运行的 ZCode 单实例接管），重置 pid 并抛出
  /// 可读错误，避免留下“记录死 pid + 状态错乱”的假象。
  Future<RuntimeInstance> start(String id) async {
    final meta = read(id);
    if (meta == null) throw StateError('实例不存在: $id');
    final env = await buildInstanceEnv(id);
    final exe = paths.findZCodeExe();
    if (exe == null || !File(exe).existsSync()) {
      throw StateError('找不到 ZCode 可执行文件，已尝试：\n'
          '  /Applications/ZCode.app\n'
          '  ${p.join(paths.home, 'Applications', 'ZCode.app')}\n'
          '请确认 ZCode 已安装。');
    }
    Directory(paths.instanceDataRoot(id)).createSync(recursive: true);

    final int pid;
    try {
      final proc = await Process.start(exe, const [],
          environment: env, mode: ProcessStartMode.detached);
      proc.stdin.close();
      pid = proc.pid;
    } on ProcessException catch (e) {
      throw StateError('ZCode 启动失败（$exe）：${e.message}（errno ${e.errorCode}）');
    }

    // 等待 1s 再校验：Electron 单实例接管 / 崩溃都会在这个窗口内退出。
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!await _pidAlive(pid)) {
      _writeMeta(RuntimeInstance(
        id: meta.id,
        name: meta.name,
        pid: null,
        bindAccountId: meta.bindAccountId,
        managed: true,
      ));
      throw StateError('ZCode 进程启动后立即退出（PID $pid）。'
          '通常是被正在运行的 ZCode 单实例接管：请先退出其他 ZCode 窗口，再启动本实例。'
          '实例状态已重置。');
    }

    final started = RuntimeInstance(
      id: meta.id,
      name: meta.name,
      pid: pid,
      bindAccountId: meta.bindAccountId,
      managed: true,
    );
    _writeMeta(started);
    return started;
  }

  /// 校验 pid 是否存活（跨平台：ps / tasklist）。
  Future<bool> _pidAlive(int pid) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
        return (r.stdout as String).contains(pid.toString());
      }
      final r = await Process.run('ps', ['-p', pid.toString(), '-o', 'pid=']);
      return (r.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 构造实例独立环境：HOME/临时目录指向实例数据目录，登录态隔离。
  /// 环境变量与 Electron 版 (instance.js buildInstanceEnv) 对齐。
  Future<Map<String, String>> buildInstanceEnv(String id) async {
    final meta = read(id);
    if (meta == null) throw StateError('实例不存在: $id');
    final root = paths.instanceRoot(id);
    final dataDir = paths.instanceDataRoot(id);
    final electronDir = p.join(root, 'electron');
    final sessionDir = p.join(electronDir, 'session');
    final v2Dir = p.join(dataDir, '.zcode', 'v2');
    Directory(v2Dir).createSync(recursive: true);
    Directory(sessionDir).createSync(recursive: true);
    Directory(p.join(dataDir, 'tmp')).createSync(recursive: true);

    final store = _store;
    final bindAccountId = meta.bindAccountId;
    if (bindAccountId != null && store != null) {
      try {
        store.load(bindAccountId);
      } catch (_) {
        throw StateError('绑定的账号快照已删除，无法启动。请删除此实例后重新创建，或创建时不绑定账号。');
      }
      final snap = store.load(bindAccountId);
      atomicWrite(p.join(v2Dir, 'credentials.json'), snap.credentials);
      atomicWrite(p.join(v2Dir, 'config.json'), snap.config);
      _clearInstanceCache(dataDir);
    }

    // Windows 上不重定向 HOME/USERPROFILE（与 Electron 版一致，
    // ZCode 靠 ZCODE_DESKTOP_HOME_DIR / ZCODE_DATA_BASE_DIR 定位数据）。
    return {
      'ZCODE_DESKTOP_USER_DATA_DIR': electronDir,
      'ZCODE_DESKTOP_SESSION_DATA_DIR': sessionDir,
      'ZCODE_DATA_BASE_DIR': dataDir,
      'ZCODE_DESKTOP_HOME_DIR': dataDir,
      'ZCODE_CREDENTIAL_SECRET': defaultCredentialSecret(),
      'ZCODE_DESKTOP_APPLICATION_NAME': 'ZCode [${meta.name}]',
      if (!Platform.isWindows) ...{
        'USERPROFILE': dataDir,
        'HOME': dataDir,
        'TMPDIR': p.join(dataDir, 'tmp'),
      },
    };
  }

  void _clearInstanceCache(String dataDir) {
    for (final rel in const [
      '.cache',
      '.zcode/coding-cache',
      '.zcode/caching',
    ]) {
      try {
        final target = p.join(dataDir, rel);
        final f = File(target);
        if (f.existsSync()) {
          f.deleteSync();
          continue;
        }
        final d = Directory(target);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  RuntimeInstance? read(String id) {
    final f = File(metaFile(id));
    if (!f.existsSync()) return null;
    try {
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return RuntimeInstance(
        id: (json['id'] ?? 'inst').toString(),
        name: (json['name'] ?? 'ZCode').toString(),
        pid: json['pid'] as int?,
        bindAccountId: json['bindAccountId'] as String?,
        managed: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> stop(String id) async {
    final meta = read(id);
    if (meta == null) throw StateError('实例不存在: $id');
    final pid = meta.pid;
    var stopped = false;
    if (pid != null && pid > 0) {
      try {
        if (Process.killPid(pid, ProcessSignal.sigterm)) {
          stopped = await _waitExit(pid, const Duration(seconds: 3));
        }
      } catch (_) {}
      if (!stopped) {
        try {
          stopped = Process.killPid(pid, ProcessSignal.sigkill);
        } catch (_) {
          stopped = false;
        }
      }
    }
    final updated = RuntimeInstance(
      id: meta.id,
      name: meta.name,
      pid: null,
      bindAccountId: meta.bindAccountId,
      managed: true,
    );
    _writeMeta(updated);
    return stopped;
  }

  Future<bool> _waitExit(int pid, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final infos = await platform.runningZcodeProcesses();
        if (infos.every((p) => p.pid != pid)) return true;
      } catch (_) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<bool> remove(String id) async {
    try {
      await stop(id);
    } catch (_) {}
    try {
      final root = Directory(paths.instanceRoot(id));
      if (root.existsSync()) root.deleteSync(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 合并受管实例与运行时进程（纯函数，便于测试）。
  ///
  /// 认领规则：pid 匹配（spawn 记录），或应用名匹配——多开实例的应用名
  /// 固定为 "ZCode [<实例名>]"（ZCODE_DESKTOP_APPLICATION_NAME），spawn 后
  /// Electron 可能重新拉起主进程导致 pid 变化，名称认领能兜住这种情况。
  /// 认领到多个进程时取名称匹配的那个 pid 作为有效 pid（真正的应用进程）。
  static List<RuntimeInstance> mergeRuntimeInstances(
    List<RuntimeInstance> managed,
    List<RuntimeProcess> running,
  ) {
    final results = <RuntimeInstance>[];
    final matchedPids = <int>{};

    for (final instance in managed) {
      final expectedName = 'ZCode [${instance.name}]';
      RuntimeProcess? byName;
      var byPid = false;
      for (final proc in running) {
        if (instance.pid != null && proc.pid == instance.pid) {
          byPid = true;
          matchedPids.add(proc.pid);
        }
        if (proc.name == expectedName) {
          byName ??= proc;
          matchedPids.add(proc.pid);
        }
      }
      final effectivePid = byName?.pid ?? (byPid ? instance.pid : null);
      results.add(RuntimeInstance(
        id: instance.id,
        name: instance.name,
        pid: effectivePid,
        bindAccountId: instance.bindAccountId,
        running: effectivePid != null,
        managed: true,
      ));
    }

    // 外部运行实例：未被任何受管实例认领的进程
    final externals = running
        .where((proc) => !matchedPids.contains(proc.pid))
        .map((proc) => RuntimeInstance(
              id: 'external-${proc.pid}',
              name: proc.name ?? 'ZCode',
              pid: proc.pid,
              running: true,
              managed: false,
              exePath: proc.path,
            ))
        .toList()
      ..sort((a, b) => (a.pid ?? 0).compareTo(b.pid ?? 0));
    results.addAll(externals);
    return results;
  }

  /// 解析实例内登录的账号。
  ///
  /// - 受管实例：读自身隔离数据目录的登录态；
  /// - 外部实例：共享主目录 ~/.zcode/v2 的登录态（与 Electron 版行为一致），
  ///   所有外部进程显示同一个主账号。
  Future<RuntimeInstance> _withAccount(RuntimeInstance instance) async {
    final v2 = instance.managed
        ? p.join(paths.instanceDataRoot(instance.id), '.zcode', 'v2')
        : paths.zcodeV2Dir;
    final creds = File(p.join(v2, 'credentials.json'));
    final cfg = File(p.join(v2, 'config.json'));
    InstanceAccount? account;
    if (creds.existsSync() && cfg.existsSync()) {
      try {
        final fp = await extractFingerprint(
          credentialsFile: creds.path,
          configFile: cfg.path,
          secret: _secret,
        );
        if (fp != null) {
          account = InstanceAccount(
            id: fp.shortId,
            label: fp.label,
            email: fp.email,
            name: fp.name,
            provider: fp.provider,
          );
        }
      } catch (_) {}
    }
    return RuntimeInstance(
      id: instance.id,
      name: instance.name,
      pid: instance.pid,
      bindAccountId: instance.bindAccountId,
      running: instance.running,
      managed: instance.managed,
      account: account,
      exePath: instance.exePath,
    );
  }
}
