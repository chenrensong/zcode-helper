import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/account_models.dart';
import '../core/fingerprint.dart';
import 'theme.dart';
import 'widgets.dart';

/// 顶部状态条：主目录登录态 + 运行的 ZCode 实例（多开逐个展示、外部聚合，5s 轮询）。
class StatusHeader extends StatefulWidget {
  const StatusHeader({super.key, required this.services});

  final AppServices services;

  @override
  State<StatusHeader> createState() => _StatusHeaderState();
}

class _StatusHeaderState extends State<StatusHeader> {
  Timer? _timer;
  late Fingerprint? _current;

  @override
  void initState() {
    super.initState();
    _current = widget.services.state.current;
    widget.services.state.addListener(_onState);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => widget.services.state.refresh());
  }

  void _onState() {
    if (!mounted) return;
    setState(() => _current = widget.services.state.current);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.services.state.removeListener(_onState);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final running = services.state.runningInstances;
    final loginFiles = services.paths.hasLoginFiles;
    // 多开模型：外部 ZCode 全部共享主目录登录态，聚合为一个；
    // 多开实例各自带账号展示。
    final managedRunning = running.where((r) => r.managed).toList();
    final externals = running.where((r) => !r.managed).toList();

    final refresh = TextButton.icon(
      onPressed: () => services.state.refresh(),
      icon: const Icon(Icons.refresh_rounded, size: 16),
      label: const Text('刷新'),
    );

    return Builder(
      builder: (context) {
        final tokens = ZcodeTokens.of(context);
        // 主目录登录段（Flexible 保护：账号名过长时省略号截断）。
        // 区分「未加载」（从未刷新成功过，中性提示）与「读取失败」
        // （刷新过但凭据加密/格式异常），避免启动时误闪错误态。
        final Widget mainLoginInfo;
        if (!loginFiles) {
          mainLoginInfo =
              const Flexible(child: _Chip(color: ZcodePalette.warning, label: '未登录'));
        } else if (_current != null) {
          mainLoginInfo = Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: _Chip(color: ZcodePalette.success, label: _current!.label)),
                const SizedBox(width: 6),
                ProviderBadge(provider: _current!.provider),
              ],
            ),
          );
        } else if (services.state.lastRefreshedAt == null) {
          mainLoginInfo =
              Flexible(child: _Chip(color: tokens.mutedForeground, label: '读取中…'));
        } else {
          mainLoginInfo = Flexible(
            child: _Chip(color: tokens.mutedForeground, label: '读取失败（凭据已加密/格式异常）'),
          );
        }
        final mainLoginSection = Tooltip(
          message: '共享主目录（~/.zcode）的登录态：账号页「切换」写入这里，'
              '非本工具启动的 ZCode 也使用它',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt_rounded, size: 18, color: ZcodePalette.brand),
              const SizedBox(width: 8),
              Text('主目录', style: TextStyle(fontSize: 12, color: tokens.mutedForeground)),
              const SizedBox(width: 10),
              mainLoginInfo,
            ],
          ),
        );

        // 运行实例段：多开实例逐个展示，外部聚合
        final instanceChips = <Widget>[
          for (final r in managedRunning) _InstanceChip(instance: r),
          if (externals.isNotEmpty)
            Tooltip(
              message: '非本工具启动的 ZCode：${externals.map((e) => 'PID ${e.pid}').join('、')}\n'
                  '共享主目录登录态',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: tokens.border),
                ),
                child: Text(
                  '外部 ZCode ×${externals.length}',
                  style: TextStyle(fontSize: 11, color: tokens.mutedForeground),
                ),
              ),
            ),
        ];
        final instancesSection = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.laptop_mac_rounded, size: 16, color: tokens.subtleForeground),
            const SizedBox(width: 6),
            Text('运行实例', style: TextStyle(fontSize: 12, color: tokens.mutedForeground)),
            const SizedBox(width: 8),
            if (instanceChips.isEmpty)
              Text('无', style: TextStyle(fontSize: 12, color: tokens.mutedForeground))
            else
              Flexible(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: instanceChips,
                ),
              ),
          ],
        );

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          color: tokens.background,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 窄窗口：登录与实例分两行，避免单行溢出
              if (constraints.maxWidth < 780) {
                return Column(
                  children: [
                    Row(children: [Expanded(child: mainLoginSection), refresh]),
                    const SizedBox(height: 4),
                    instancesSection,
                  ],
                );
              }
              return Row(children: [
                mainLoginSection,
                const SizedBox(width: 14),
                Expanded(child: instancesSection),
                refresh,
              ]);
            },
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
    );
    return child;
  }
}

class _InstanceChip extends StatelessWidget {
  const _InstanceChip({required this.instance});

  final RuntimeInstance instance;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    final label = instance.managed
        ? '${instance.name}${instance.account != null ? ' · ${instance.account!.displayLabel}' : ''}'
        : '外部 ZCode (${instance.pid})'
            '${instance.account != null ? ' · ${instance.account!.displayLabel}' : ''}';
    return Tooltip(
      message: instance.managed
          ? '本工具启动的多开实例${instance.account != null ? '，账号 ${instance.account!.displayLabel}' : ''}'
          : '非本工具启动的 ZCode（共享主目录登录态）',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: instance.managed ? tokens.surfaceHover : tokens.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: instance.managed ? tokens.borderHover : tokens.border),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: tokens.mutedForeground),
        ),
      ),
    );
  }
}
