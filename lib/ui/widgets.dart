import 'package:flutter/material.dart';

import '../core/account_models.dart';
import 'theme.dart';

void showToast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      // 错误底色在明暗主题下都偏深，强制白色前景保证对比度
      content: Text(message, style: error ? const TextStyle(color: Colors.white) : null),
      backgroundColor: error ? const Color(0xFFB3544E) : ZcodeTokens.of(context).cardSelected,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  String okLabel = '确认',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: const Color(0xFF8C3A3A))
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(okLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

class ProviderBadge extends StatelessWidget {
  const ProviderBadge({super.key, required this.provider});

  final String? provider;

  @override
  Widget build(BuildContext context) {
    final isBig = ZcodePalette.isBigModel(provider);
    final color = ZcodePalette.providerColor(provider);
    final label = isBig ? 'BigModel' : 'Z.ai';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProviderMark(size: 12, provider: provider),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class HealthChip extends StatelessWidget {
  const HealthChip({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'healthy' => (ZcodePalette.success, '正常'),
      'warning' => (ZcodePalette.warning, '需注意'),
      'error' => (ZcodePalette.error, '异常'),
      _ => (Colors.grey, status),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

class QuotaMeter extends StatelessWidget {
  const QuotaMeter({super.key, required this.item});

  final QuotaItem item;

  @override
  Widget build(BuildContext context) {
    final color = switch (item.status) {
      'exhausted' => ZcodePalette.error,
      'low' => const Color(0xFFF0716D),
      'warning' => ZcodePalette.warning,
      _ => ZcodePalette.brand,
    };
    // 剩余口径展示：进度条按剩余比例填充，数值显示剩余量；附带窗口重置时间
    final remaining = (item.quota - item.used).clamp(0.0, double.infinity);
    final display = item.kind == 'quota_limit'
        ? '${_fmt(remaining)}%'
        : '${_fmt(remaining)} / ${_fmt(item.quota)}';
    final reset = _resetLabel(item.resetAt);
    final subtle = ZcodeTokens.of(context).subtleForeground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(item.label, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (reset == null)
              Text(display, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))
            else
              Text.rich(
                TextSpan(
                  text: display,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  children: [
                    TextSpan(
                      text: ' · $reset',
                      style: TextStyle(fontSize: 11, color: subtle),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: item.quota > 0 ? (remaining / item.quota).clamp(0.0, 1.0) : 0.0,
            minHeight: 6,
            backgroundColor: ZcodeTokens.of(context).surfaceHover,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }

  String _fmt(double v) => (v >= 1000000)
      ? '${(v / 1000000).toStringAsFixed(1)}M'
      : (v >= 1000)
          ? '${(v / 1000).toStringAsFixed(1)}K'
          : v.toStringAsFixed(0);

  /// 重置时间：今天显示「HH:mm 重置」，其他天显示「M月d日 重置」。
  String? _resetLabel(int? ms) {
    if (ms == null || ms <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (sameDay) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm 重置';
    }
    return '${dt.month}月${dt.day}日 重置';
  }
}

String formatDateTime(int? ms) {
  if (ms == null || ms <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: tokens.subtleForeground.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: tokens.subtleForeground, fontSize: 13)),
        ],
      ),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!, style: TextStyle(fontSize: 12, color: ZcodeTokens.of(context).subtleForeground)),
          ),
      ],
    );
  }
}
