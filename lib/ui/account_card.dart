import 'package:flutter/material.dart';

import '../core/account_models.dart';
import 'theme.dart';
import 'widgets.dart';

class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.entry,
    this.quota,
    required this.onSwitch,
    required this.onRename,
    required this.onDelete,
  });

  final AccountEntry entry;
  final QuotaOverview? quota;
  final VoidCallback onSwitch;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final meta = entry.meta;
    final accent = ZcodePalette.providerColor(meta.provider);
    final health = entry.health;
    final tokens = ZcodeTokens.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProviderMark(size: 32, provider: meta.provider),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meta.shortLabel,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      if (meta.userId != null)
                        Text(
                          '${meta.userId!.length >= 10 ? '…${meta.userId!.substring(meta.userId!.length - 10)}' : meta.userId}'
                          ' · ${formatDateTime(meta.capturedAt)}',
                          style: TextStyle(fontSize: 11, color: tokens.subtleForeground),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rename') onRename();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名 / 备注')),
                    PopupMenuItem(value: 'delete', child: Text('删除快照')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 徽章用 Wrap：窄卡片放不下时自动换行而不是横向溢出
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ProviderBadge(provider: meta.provider),
                if (health != null)
                  Tooltip(
                    message: health.summary,
                    child: HealthChip(status: health.status),
                  )
                else
                  const HealthChip(status: 'error'),
                if (entry.sizeKb != null)
                  Text('${entry.sizeKb} KB',
                      style: TextStyle(fontSize: 11, color: tokens.subtleForeground)),
              ],
            ),
            if (health != null && health.status != 'healthy' && health.summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      health.status == 'error' ? Icons.error_outline_rounded : Icons.info_outline_rounded,
                      size: 13,
                      color: health.status == 'error'
                          ? ZcodePalette.error
                          : ZcodePalette.warning.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        health.summary,
                        style: TextStyle(
                          fontSize: 11,
                          color: health.status == 'error'
                              ? tokens.errorMuted
                              : tokens.subtleForeground,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (quota != null && quota!.isOk) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: tokens.border),
              const SizedBox(height: 8),
              if (quota!.plan != null)
                Row(
                  children: [
                    const Icon(Icons.workspace_premium_rounded, size: 14, color: ZcodePalette.commandNode),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: quota!.plan!.label,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600, color: ZcodePalette.commandNode),
                          children: [
                            if (quota!.plan!.billingCycle != null)
                              TextSpan(
                                text: ' · ${quota!.plan!.billingCycle}',
                                style: TextStyle(
                                    fontSize: 11, color: tokens.subtleForeground),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              for (final item in quota!.items.take(3)) ...[
                const SizedBox(height: 6),
                QuotaMeter(item: item),
              ],
            ] else if (quota != null && !quota!.isOk) ...[
              const SizedBox(height: 8),
              Text(
                quota!.error ?? '额度查询失败',
                style: TextStyle(fontSize: 11, color: tokens.errorMuted),
              ),
            ],
            const SizedBox(height: 10),
            // Spacer 把按钮钉在卡片底部：内容多少不同，卡片仍视觉统一
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onSwitch,
                style: FilledButton.styleFrom(
                  backgroundColor: accent.withValues(alpha: 0.22),
                  foregroundColor: accent,
                ),
                icon: const Icon(Icons.swap_horizontal_circle_rounded, size: 18),
                label: const Text('切换并重启'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
