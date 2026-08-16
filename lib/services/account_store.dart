import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/account_models.dart';
import '../core/fingerprint.dart';
import '../core/paths.dart';
import 'account_health.dart';
import 'fs_utils.dart';

class CaptureResult {
  const CaptureResult({
    required this.id,
    this.meta,
    this.created = false,
    this.skipped = false,
    this.message,
  });

  final String id;
  final AccountMeta? meta;
  final bool created;
  final bool skipped;
  final String? message;
}

class ImportResult {
  const ImportResult({required this.imported, required this.skipped});

  final List<Map<String, dynamic>> imported;
  final List<Map<String, dynamic>> skipped;

  int get count => imported.length;
}

class AccountStore {
  AccountStore(this.paths, {String? secret}) {
    _secret = secret;
  }

  final AppPaths paths;
  String? _secret;

  String metaPath(String id) => p.join(paths.storeDir, '$id.meta.json');
  String snapPath(String id) => p.join(paths.storeDir, '$id.snap.json');

  void ensureStore() {
    Directory(paths.storeDir).createSync(recursive: true);
  }

  String safeId(String id) {
    final s = id.trim();
    if (!RegExp(r'^[a-zA-Z0-9_-]{4,64}$').hasMatch(s)) {
      throw ArgumentError('非法账号 id: $s');
    }
    return s;
  }

  /// 列出所有已保存账号（含健康检查）。
  Future<List<AccountEntry>> list() async {
    ensureStore();
    final files = Directory(paths.storeDir)
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((name) => name.endsWith('.meta.json'))
        .toList();
    final result = <AccountEntry>[];
    for (final name in files) {
      try {
        final metaJson = jsonDecode(File(p.join(paths.storeDir, name)).readAsStringSync());
        final meta = AccountMeta.fromJson(Map<String, dynamic>.from(metaJson as Map));
        int? sizeKb;
        AccountHealth? health;
        try {
          final snapFile = File(snapPath(meta.id));
          if (snapFile.existsSync()) {
            sizeKb = (snapFile.lengthSync() / 1024).round();
            final snap = jsonDecode(snapFile.readAsStringSync());
            health = await validateSnapshot(Snapshot.fromJson(Map<String, dynamic>.from(snap as Map)), meta: meta, secret: _secret);
          }
        } catch (_) {}
        result.add(AccountEntry(meta: meta, sizeKb: sizeKb, health: health));
      } catch (_) {}
    }
    result.sort((a, b) => (a.meta.capturedAt ?? 0).compareTo(b.meta.capturedAt ?? 0));
    return result;
  }

  /// 从当前登录态捕获新快照。
  Future<CaptureResult> capture({
    String? label,
    String note = '',
    bool overwrite = false,
  }) async {
    ensureStore();
    final fp = await extractFingerprint(
      credentialsFile: paths.credentialsFile,
      configFile: paths.configFile,
      secret: _secret,
    );
    if (fp == null) {
      throw StateError('无法从当前登录态提取账号指纹（请先在 ZCode 里登录任意账号，或先在设置中授权 ZCode 数据目录）');
    }

    final id = fp.emailShortId.isNotEmpty ? fp.emailShortId : fp.shortId;
    if (File(metaPath(id)).existsSync() && !overwrite) {
      final oldMeta = AccountMeta.fromJson(
          Map<String, dynamic>.from(jsonDecode(File(metaPath(id)).readAsStringSync()) as Map));
      return CaptureResult(id: id, meta: oldMeta, skipped: true, message: '该账号已存在（${oldMeta.displayLabel}）');
    }

    final snap = _readCurrentSnapshot();
    // 快照写入走原子写,避免进程中断留下半个 JSON
    atomicWrite(snapPath(id), jsonEncode({'credentials': snap.credentials, 'config': snap.config}));
    final meta = AccountMeta(
      id: id,
      shortId: fp.shortId,
      emailShortId: fp.emailShortId.isNotEmpty ? fp.emailShortId : fp.shortId,
      userId: fp.userId,
      provider: fp.provider,
      label: (label == null || label.trim().isEmpty) ? fp.label : label.trim(),
      email: fp.email,
      name: fp.name,
      avatar: fp.avatar,
      customerId: fp.customerId,
      userKey: fp.userKey,
      source: fp.source,
      note: note,
      capturedAt: DateTime.now().millisecondsSinceEpoch,
    );
    writeJsonPretty(metaPath(id), meta.toJson());
    return CaptureResult(id: id, meta: meta, created: true);
  }

  Snapshot _readCurrentSnapshot() {
    return Snapshot(
      credentials: File(paths.credentialsFile).readAsStringSync(),
      config: File(paths.configFile).readAsStringSync(),
    );
  }

  /// 读取账号快照（不切换）。
  Snapshot load(String id) {
    final safe = safeId(id);
    final f = File(snapPath(safe));
    if (!f.existsSync()) throw StateError('找不到账号快照: $safe');
    final snap = Snapshot.fromJson(Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map));
    if (snap == null) throw StateError('账号快照损坏: $safe');
    return snap;
  }

  bool remove(String id) {
    // 与 load 一致先做 safeId 校验,防止路径穿越
    final safe = safeId(id);
    var removed = 0;
    for (final f in [metaPath(safe), snapPath(safe)]) {
      try {
        File(f).deleteSync();
        removed++;
      } catch (_) {}
    }
    return removed > 0;
  }

  AccountMeta rename(String id, String? label, String? note) {
    final safe = safeId(id);
    if (!File(metaPath(safe)).existsSync()) throw StateError('找不到账号: $safe');
    final meta = AccountMeta.fromJson(Map<String, dynamic>.from(jsonDecode(File(metaPath(safe)).readAsStringSync()) as Map));
    final updated = AccountMeta(
      id: meta.id,
      shortId: meta.shortId,
      emailShortId: meta.emailShortId,
      userId: meta.userId,
      provider: meta.provider,
      label: (label != null && label.trim().isNotEmpty) ? label.trim() : meta.label,
      email: meta.email,
      name: meta.name,
      avatar: meta.avatar,
      customerId: meta.customerId,
      userKey: meta.userKey,
      source: meta.source,
      // note 仅在显式传入时覆盖;null 表示调用方不想改动备注
      note: note ?? meta.note,
      capturedAt: meta.capturedAt,
    );
    writeJsonPretty(metaPath(safe), updated.toJson());
    return updated;
  }

  /// 导出账号快照（默认全部）。
  Map<String, dynamic> exportAccounts(List<String>? ids) {
    ensureStore();
    final wanted = (ids != null && ids.isNotEmpty) ? ids.map(safeId).toSet() : null;
    final metas = Directory(paths.storeDir)
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((n) => n.endsWith('.meta.json'))
        .toList();
    final accounts = <Map<String, dynamic>>[];
    for (final name in metas) {
      try {
        final meta = jsonDecode(File(p.join(paths.storeDir, name)).readAsStringSync());
        final accountId = (meta as Map)['id'] as String;
        if (wanted != null && !wanted.contains(accountId)) continue;
        final snap = File(snapPath(accountId));
        if (!snap.existsSync()) continue;
        accounts.add({
          'meta': meta,
          'snapshot': jsonDecode(snap.readAsStringSync()),
        });
      } catch (_) {}
    }
    return {
      'version': 1,
      'app': 'zcode-helper',
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'accounts': accounts,
    };
  }

  /// 导入账号快照，默认跳过已存在。
  ImportResult importAccounts(Map<String, dynamic> payload, {bool overwrite = false}) {
    ensureStore();
    final accounts = payload['accounts'];
    if (accounts is! List) throw ArgumentError('导入文件缺少 accounts 数组');
    final imported = <Map<String, dynamic>>[];
    final skipped = <Map<String, dynamic>>[];
    for (final item in accounts) {
      try {
        if (item is! Map) throw ArgumentError('导入条目格式不正确');
        final metaRaw = item['meta'];
        final snapRaw = item['snapshot'];
        if (metaRaw is! Map || snapRaw is! Map) throw ArgumentError('缺少 snapshot');
        final id = safeId(metaRaw['id'] as String? ?? '');
        final snap = Snapshot.fromJson(Map<String, dynamic>.from(snapRaw));
        if (snap == null) throw ArgumentError('snapshot 缺少 credentials/config');
        if (!overwrite && (File(metaPath(id)).existsSync() || File(snapPath(id)).existsSync())) {
          skipped.add({'id': id, 'label': metaRaw['label'], 'reason': '已存在'});
          continue;
        }
        atomicWrite(snapPath(id), jsonEncode({'credentials': snap.credentials, 'config': snap.config}));
        final cleanMeta = Map<String, dynamic>.from(metaRaw)..['id'] = id;
        writeJsonPretty(metaPath(id), cleanMeta);
        imported.add({'id': id, 'label': cleanMeta['label'] ?? cleanMeta['email'] ?? id});
      } catch (e) {
        skipped.add({
          'id': item is Map ? item['meta'] is Map ? (item['meta'] as Map)['id'] : null : null,
          'reason': e.toString(),
        });
      }
    }
    return ImportResult(imported: imported, skipped: skipped);
  }

  /// 当前登录态指纹（status 用）。
  Future<Fingerprint?> current() => extractFingerprint(
        credentialsFile: paths.credentialsFile,
        configFile: paths.configFile,
        secret: _secret,
      );

  Future<AccountHealth> healthFor(Snapshot snapshot, {AccountMeta? meta}) =>
      validateSnapshot(snapshot, meta: meta, secret: _secret);
}
