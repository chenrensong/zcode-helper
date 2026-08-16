import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app.dart';
import '../core/account_models.dart';
import 'account_card.dart';
import 'login_dialog.dart';
import 'switch_dialog.dart';
import 'theme.dart';
import 'widgets.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.services});

  final AppServices services;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  List<AccountEntry> _entries = const [];
  Map<String, QuotaOverview> _quotas = const {};
  bool _loading = true;
  Timer? _timer;
  // 配额轮询防竞态：记录每个账号最近一轮请求的发起时间，
  // 旧请求的响应回来时若已发起更新一轮，则丢弃旧响应。
  final Map<String, DateTime> _quotaFetchStartedAt = {};

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final entries = await widget.services.store.list();
      if (!mounted) return;
      _entries = entries;
      for (final entry in entries) {
        _fetchQuota(entry.meta.id);
      }
      setState(() {});
    } catch (_) {
      // 列表读取失败：保留旧数据，只在用户主动刷新时打扰
      if (mounted && !quiet) showToast(context, '账号列表读取失败', error: true);
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  Future<void> _fetchQuota(String id) async {
    Snapshot snapshot;
    try {
      snapshot = widget.services.store.load(id);
    } catch (_) {
      return;
    }
    final startedAt = DateTime.now();
    _quotaFetchStartedAt[id] = startedAt;
    final overview = await widget.services.quota.overviewFromSnapshot(snapshot);
    if (!mounted) return;
    if (_quotaFetchStartedAt[id] != startedAt) return;
    setState(() => _quotas = {..._quotas, id: overview});
  }

  // ---- 登录 ----
  Future<void> _login() async {
    final services = widget.services;
    final provider = await showProviderPicker(context);
    if (provider == null || !mounted) return;
    final result = await showLoginDialog(context, provider, services.loginController);
    if (result == null || !mounted) return;
    final who = result.email?.isNotEmpty == true
        ? result.email!
        : (result.account?.displayLabel ?? provider);
    showToast(context, '${result.skipped ? '已有同名账号，快照已更新' : '登录成功'}：$who');
    await services.state.refresh();
    await _load(quiet: true);
  }

  // ---- 捕获 ----
  Future<void> _capture() async {
    final services = widget.services;
    try {
      if (!services.paths.hasLoginFiles) {
        if (!mounted) return;
        showToast(context, '未找到登录态：请先在 ZCode 登录账号后重试', error: true);
        return;
      }
      final result = await services.store.capture();
      if (!mounted) return;
      if (result.skipped) {
        showToast(context, result.message ?? '该账号已存在');
      } else {
        showToast(context, '已捕获账号：${result.meta?.displayLabel ?? result.id}');
      }
    } catch (e) {
      if (mounted) showToast(context, '捕获失败：$e', error: true);
    } finally {
      if (mounted) {
        await services.state.refresh();
        await _load(quiet: true);
      }
    }
  }

  // ---- 切换 ----
  Future<void> _switchTo(AccountEntry entry) async {
    final services = widget.services;
    Snapshot snapshot;
    try {
      snapshot = services.store.load(entry.meta.id);
    } catch (e) {
      showToast(context, '快照读取失败: $e', error: true);
      return;
    }
    if (!mounted) return;
    final outcome = await showSwitchDialog(
      context,
      services,
      id: entry.meta.id,
      snapshot: snapshot,
    );
    if (!mounted) return;
    if (outcome.result != null) {
      final r = outcome.result!;
      final modeText = switch (r.mode) {
        'guided-quit' => '你已手动退出 ZCode',
        'auto-restart' => '已自动重启',
        _ => 'ZCode 未运行，已写入登录态',
      };
      showToast(context, '切换完成（$modeText）');
    } else if (outcome.error != null) {
      _showError('切换失败', outcome.error!);
    }
    await services.state.refresh();
    await _load(quiet: true);
  }

  void _showError(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  // ---- 回滚 ----
  Future<void> _rollback() async {
    if (!await confirmDialog(
      context,
      title: '回滚到上次备份',
      body: '将恢复最近一次切换/操作前的 ZCode 登录态（.last 备份）。ZCode 需重新启动生效。',
      okLabel: '回滚',
      danger: true,
    )) {
      return;
    }
    try {
      widget.services.switcher.rollbackToLast();
      if (!mounted) return;
      showToast(context, '已从备份恢复，重启 ZCode 后生效');
      await widget.services.state.refresh();
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
    }
  }

  // ---- 导出 / 导入 ----

  /// 用户主目录：Windows 用 USERPROFILE，macOS/Linux 用 HOME。
  String get _homeDir => Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

  /// 展开 ~/ 与 ~\ 前缀（Windows 用户习惯反斜杠）。
  String _expandTilde(String path) {
    if (path.startsWith('~/')) return '$_homeDir/${path.substring(2)}';
    if (path.startsWith('~\\')) return '$_homeDir\\${path.substring(2)}';
    return path;
  }

  Future<void> _export() async {
    final payload = widget.services.store.exportAccounts(null);
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    final target = p.join(
      _homeDir,
      'Downloads',
      'zcode-helper-accounts-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    var written = false;
    try {
      await File(target).writeAsString(json);
      written = true;
    } catch (_) {}
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导出账号（${(payload['accounts'] as List).length} 个）'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                written
                    ? '已写入：$target\n文件含登录凭据，注意保管。'
                    : '当前环境无法写文件，请复制下方内容手动保存：',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Container(
                height: 220,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: ZcodeTokens.of(ctx).background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ZcodeTokens.of(ctx).border),
                ),
                child: SelectableText(json, style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
      ),
    );
  }

  Future<void> _import() async {
    final pathCtrl = TextEditingController();
    final pasteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入账号快照'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: pathCtrl,
                decoration: const InputDecoration(
                  labelText: 'JSON 文件路径（可选）',
                  hintText: '例如 ~/Downloads/zcode-helper-accounts-xxxx.json',
                ),
              ),
              const SizedBox(height: 12),
              const Text('或直接粘贴导出的 JSON：', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: pasteCtrl,
                maxLines: 8,
                decoration: const InputDecoration(hintText: '{"version":1, "accounts":[...]}'),
              ),
              const SizedBox(height: 8),
              Text('已存在的账号将自动跳过。',
                  style: TextStyle(fontSize: 11, color: ZcodeTokens.of(ctx).subtleForeground)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    // 对话框已关闭，读取输入后立即释放控制器
    final pathInput = pathCtrl.text.trim();
    final pastedInput = pasteCtrl.text.trim();
    pathCtrl.dispose();
    pasteCtrl.dispose();
    if (ok != true) return;

    String json;
    final pathText = _expandTilde(pathInput);
    if (pathText.isNotEmpty) {
      try {
        json = File(pathText).readAsStringSync();
      } catch (e) {
        if (!mounted) return;
        showToast(context, '文件读取失败: $e', error: true);
        return;
      }
    } else {
      json = pastedInput;
    }
    try {
      final payload = jsonDecode(json) as Map<String, dynamic>;
      final result = widget.services.store.importAccounts(payload);
      if (!mounted) return;
      showToast(context, '导入 ${result.count} 个，跳过 ${result.skipped.length} 个');
      await _load(quiet: true);
    } catch (e) {
      if (!mounted) return;
      showToast(context, '导入失败: $e', error: true);
    }
  }

  // ---- 重命名 / 删除 ----
  Future<void> _rename(AccountEntry entry) async {
    final labelCtrl = TextEditingController(text: entry.meta.label ?? '');
    final noteCtrl = TextEditingController(text: entry.meta.note ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名 / 备注'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: labelCtrl, decoration: const InputDecoration(labelText: '显示名称')),
              const SizedBox(height: 10),
              TextField(controller: noteCtrl, maxLines: 3, decoration: const InputDecoration(labelText: '备注')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    // 对话框已关闭，读取输入后立即释放控制器
    final labelInput = labelCtrl.text;
    final noteInput = noteCtrl.text;
    labelCtrl.dispose();
    noteCtrl.dispose();
    if (ok != true) return;
    try {
      widget.services.store.rename(entry.meta.id, labelInput, noteInput);
      if (!mounted) return;
      showToast(context, '已保存');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败：$e', error: true);
      return;
    }
    await _load(quiet: true);
  }

  Future<void> _delete(AccountEntry entry) async {
    if (!await confirmDialog(
      context,
      title: '删除账号快照',
      body: '仅删除本地快照（快照/元数据文件），不影响 ZCode 当前登录状态。',
      okLabel: '删除',
      danger: true,
    )) {
      return;
    }
    try {
      widget.services.store.remove(entry.meta.id);
      if (!mounted) return;
      showToast(context, '已删除 ${entry.meta.displayLabel}');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '删除失败：$e', error: true);
      return;
    }
    await _load(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: _import,
          icon: const Icon(Icons.download_rounded, size: 16),
          label: const Text('导入'),
        ),
        OutlinedButton.icon(
          onPressed: _export,
          icon: const Icon(Icons.upload_rounded, size: 16),
          label: const Text('导出'),
        ),
        OutlinedButton.icon(
          onPressed: _rollback,
          icon: const Icon(Icons.history_rounded, size: 16),
          label: const Text('回滚备份'),
        ),
        FilledButton.tonalIcon(
          onPressed: _login,
          icon: const Icon(Icons.login_rounded, size: 16),
          label: const Text('登录账号'),
        ),
        FilledButton.icon(
          onPressed: _capture,
          icon: const Icon(Icons.add_a_photo_rounded, size: 16),
          label: const Text('捕获当前账号'),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // 窄窗口：标题与按钮分成上下两行，避免按钮挤压换行错乱
              if (constraints.maxWidth < 860) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const PageTitle(title: '账号快照', subtitle: '保存 / 切换 ZCode 登录态，切换前自动备份'),
                    const SizedBox(height: 10),
                    buttons,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: PageTitle(title: '账号快照', subtitle: '保存 / 切换 ZCode 登录态，切换前自动备份'),
                  ),
                  const SizedBox(width: 8),
                  buttons,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? const EmptyHint(
                        icon: Icons.photo_library_rounded,
                        text: '还没有账号快照。登录 ZCode 后点击「捕获当前账号」，切换前建议先捕获。',
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // 内容区 <700px 强制单列：避免出现两列过窄的卡片
                          final single = constraints.maxWidth < 700;
                          // 卡片高度随系统字体缩放：基准 344 按 14px 正文字号
                          // 的缩放系数等比放大，大字号下内容不再被裁切
                          final textScale =
                              MediaQuery.textScalerOf(context).scale(14) / 14;
                          return GridView.builder(
                            // 固定像素高度：所有卡片严格等高，不随宽度等比缩放
                            // （344 = 最坏内容实测 ~336 + 余量）
                            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: single ? 600 : 330,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              mainAxisExtent: 344 * textScale,
                            ),
                            itemCount: _entries.length,
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              return AccountCard(
                                entry: entry,
                                quota: _quotas[entry.meta.id],
                                onSwitch: () => _switchTo(entry),
                                onRename: () => _rename(entry),
                                onDelete: () => _delete(entry),
                              );
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
