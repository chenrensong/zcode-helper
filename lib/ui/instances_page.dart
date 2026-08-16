import 'package:flutter/material.dart';

import '../app.dart';
import '../core/account_models.dart';
import 'theme.dart';
import 'widgets.dart';

class InstancesPage extends StatefulWidget {
  const InstancesPage({super.key, required this.services});

  final AppServices services;

  @override
  State<InstancesPage> createState() => _InstancesPageState();
}

class _InstancesPageState extends State<InstancesPage> {
  List<RuntimeInstance> _instances = const [];
  List<AccountEntry> _accounts = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 首载走 loading 态；后续刷新由顶部状态条驱动的 AppState 通知
    // （shell 每 5s 调 state.refresh()），本页不再自建轮询 Timer。
    _refresh(quiet: false);
    widget.services.state.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    if (mounted) _refresh(quiet: true);
  }

  @override
  void dispose() {
    widget.services.state.removeListener(_onStateChanged);
    super.dispose();
  }

  Future<void> _refresh({bool quiet = true}) async {
    if (!quiet) setState(() => _busy = true);
    try {
      final list = await widget.services.instances.list();
      final accounts = await widget.services.store.list();
      if (!mounted) return;
      setState(() {
        _instances = list;
        _accounts = accounts;
      });
    } catch (_) {
      // 刷新失败：保留旧数据，只在用户主动刷新时打扰
      if (mounted && !quiet) showToast(context, '实例列表读取失败', error: true);
    }
    if (mounted && !quiet) setState(() => _busy = false);
  }

  Future<void> _create() async {
    final services = widget.services;
    final nameCtrl = TextEditingController();
    String? bindId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('新建实例'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '实例名称（可选）', hintText: '例如 ZCode #2'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: bindId,
                  decoration: const InputDecoration(labelText: '绑定账号（可选）'),
                  items: [
                    const DropdownMenuItem(value: 'none', child: Text('不绑定（启动后手动登录）')),
                    for (final a in _accounts)
                      DropdownMenuItem(value: a.meta.id, child: Text(a.meta.displayLabel)),
                  ],
                  onChanged: (v) => setLocal(() => bindId = (v == null || v == 'none') ? null : v),
                ),
                const SizedBox(height: 10),
                Builder(
                  builder: (ctx) => Text(
                    '绑定账号后，启动实例会使用该账号的登录态快照，各实例数据互相隔离。',
                    style: TextStyle(fontSize: 11, color: ZcodeTokens.of(ctx).subtleForeground),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
          ],
        ),
      ),
    );
    // 对话框已关闭，读取输入后立即释放控制器
    final nameInput = nameCtrl.text;
    nameCtrl.dispose();
    if (ok != true) return;
    try {
      final instance = await services.instances.create(name: nameInput, bindAccountId: bindId);
      if (!mounted) return;
      showToast(context, '已创建 ${instance.name}');
      await _refresh(quiet: false);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
    }
  }

  Future<void> _start(RuntimeInstance instance) async {
    setState(() => _busy = true);
    try {
      await widget.services.instances.start(instance.id);
      if (!mounted) return;
      showToast(context, '已启动 ${instance.name}');
      await _refresh(quiet: false);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
      setState(() => _busy = false);
    }
  }

  Future<void> _stop(RuntimeInstance instance) async {
    setState(() => _busy = true);
    try {
      await widget.services.instances.stop(instance.id);
      if (!mounted) return;
      showToast(context, '已停止 ${instance.name}');
      await _refresh(quiet: false);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
      setState(() => _busy = false);
    }
  }

  Future<void> _remove(RuntimeInstance instance) async {
    if (!await confirmDialog(
      context,
      title: '删除实例',
      body: '将停止并删除实例目录（含其登录态）。仅删除本工具管理的实例',
      okLabel: '删除',
      danger: true,
    )) {
      return;
    }
    try {
      await widget.services.instances.remove(instance.id);
      if (!mounted) return;
      showToast(context, '已删除 ${instance.name}');
      await _refresh(quiet: false);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final managed = _instances.where((i) => i.managed).toList();
    final external = _instances.where((i) => !i.managed).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Flexible(
                child: PageTitle(title: '多开实例', subtitle: '运行多个隔离的 ZCode'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('新建实例'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _busy && _instances.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      if (managed.isEmpty && external.isEmpty)
                        const EmptyHint(
                          icon: Icons.terminal_rounded,
                          text: '还没有多开实例。点击「新建实例」创建，可绑定账号快照实现登录态隔离。',
                        ),
                      for (final inst in managed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _InstanceCard(
                            instance: inst,
                            canControl: true,
                            bindLabel: _bindLabel(inst.bindAccountId),
                            bindDangling: _bindDangling(inst.bindAccountId),
                            onStart: () => _start(inst),
                            onStop: () => _stop(inst),
                            onRemove: () => _remove(inst),
                          ),
                        ),
                      if (external.isNotEmpty) ...[
                        Text('检测到的 ZCode 进程（非本工具启动）',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: ZcodeTokens.of(context).mutedForeground)),
                        const SizedBox(height: 6),
                        for (final inst in external)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _ExternalRow(instance: inst),
                          ),
                        Text(
                          '外部 ZCode 使用主目录登录态，与上面的多开实例相互独立；'
                          '在账号页「切换账号」影响的正是这些主目录实例。',
                          style: TextStyle(
                              fontSize: 11, color: ZcodeTokens.of(context).subtleForeground),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 绑定账号的显示名（找不到时回退为原始 id）。
  String _bindLabel(String? bindAccountId) {
    final id = bindAccountId;
    if (id == null) return '';
    for (final a in _accounts) {
      if (a.meta.id == id) return a.meta.displayLabel;
    }
    return id;
  }

  /// 绑定的账号快照是否已被删除（悬空绑定）。
  bool _bindDangling(String? bindAccountId) {
    final id = bindAccountId;
    if (id == null) return false;
    return !_accounts.any((a) => a.meta.id == id);
  }
}

class _InstanceCard extends StatelessWidget {
  const _InstanceCard({
    required this.instance,
    required this.canControl,
    required this.bindLabel,
    required this.bindDangling,
    required this.onStart,
    required this.onStop,
    required this.onRemove,
  });

  final RuntimeInstance instance;
  final bool canControl;
  final String bindLabel;
  final bool bindDangling;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final running = instance.running;
    final tokens = ZcodeTokens.of(context);
    final color = running ? ZcodePalette.success : tokens.subtleForeground;
    final idle = tokens.subtleForeground;
    final account = instance.account;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(instance.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      if (bindDangling)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: ZcodePalette.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Tooltip(
                            message: '绑定的账号快照已被删除，启动会失败；建议删除实例后重建',
                            child: Text(
                              '绑定账号已删除',
                              style: TextStyle(fontSize: 10, color: ZcodePalette.warning),
                            ),
                          ),
                        )
                      else if (bindLabel.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: ZcodePalette.brandSoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Tooltip(
                            message: '启动时使用该账号的登录态快照',
                            child: Text(
                              '绑定: $bindLabel',
                              style: const TextStyle(fontSize: 10, color: ZcodePalette.brand),
                            ),
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: tokens.surfaceHover,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '未绑定账号（启动后手动登录）',
                            style: TextStyle(fontSize: 10, color: tokens.subtleForeground),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    running ? '运行中 · PID ${instance.pid}' : '未运行',
                    style: TextStyle(fontSize: 11, color: running ? tokens.successMuted : idle),
                  ),
                  if (account != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '实例内账号：${account.displayLabel}${account.provider != null ? '（${account.provider}）' : ''}',
                      style: TextStyle(fontSize: 11, color: tokens.mutedForeground),
                    ),
                  ],
                ],
              ),
            ),
            if (canControl) ...[
              if (running)
                OutlinedButton(onPressed: onStop, child: const Text('停止'))
              else
                FilledButton(onPressed: onStart, child: const Text('启动')),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onRemove,
                icon: Icon(Icons.delete_outline_rounded, size: 18, color: tokens.errorMuted),
                tooltip: '删除实例',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 外部 ZCode 进程行：只读展示（含可执行路径），不提供启停。
class _ExternalRow extends StatelessWidget {
  const _ExternalRow({required this.instance});

  final RuntimeInstance instance;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    final path = instance.exePath;
    final account = instance.account;
    final accountPart = account == null ? '' : ' · ${account.displayLabel}';
    return Tooltip(
      message: path ?? '非本工具启动的 ZCode（共享主目录登录态）',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tokens.border),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: ZcodePalette.success, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'ZCode（PID ${instance.pid}）· 外部$accountPart',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  if (path != null)
                    Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: tokens.subtleForeground),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
