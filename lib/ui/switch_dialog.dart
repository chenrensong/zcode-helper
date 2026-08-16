import 'package:flutter/material.dart';

import '../app.dart';
import '../core/account_models.dart';
import '../services/switcher.dart';
import 'theme.dart';

class SwitchDialogOutcome {
  const SwitchDialogOutcome({this.result, this.error, this.cancelled = false});

  final SwitchResult? result;
  final String? error;
  final bool cancelled;
}

/// 执行切换并展示阶段进度。返回 [SwitchDialogOutcome]。
Future<SwitchDialogOutcome> showSwitchDialog(
  BuildContext context,
  AppServices services, {
  required String id,
  required Snapshot snapshot,
}) {
  return showDialog<SwitchDialogOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SwitchDialog(services: services, id: id, snapshot: snapshot),
  ).then(
    (v) => v ?? const SwitchDialogOutcome(cancelled: true),
    onError: (Object e) => SwitchDialogOutcome(error: e.toString()),
  );
}

class SwitchDialog extends StatefulWidget {
  const SwitchDialog({
    super.key,
    required this.services,
    required this.id,
    required this.snapshot,
  });

  final AppServices services;
  final String id;
  final Snapshot snapshot;

  @override
  State<SwitchDialog> createState() => _SwitchDialogState();
}

class _SwitchDialogState extends State<SwitchDialog> {
  SwitchPhase _phase = SwitchPhase.preparing;
  String _message = '';
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final services = widget.services;
    try {
      final result = await services.switcher.switchTo(
        rawSnapshot: widget.snapshot,
        snapshotId: widget.id,
        onPhase: (phase, message) {
          if (!mounted) return;
          setState(() {
            _phase = phase;
            _message = message;
          });
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      Navigator.pop(context, SwitchDialogOutcome(result: result));
    } on SwitchAborted {
      if (!mounted) return;
      Navigator.pop(context, const SwitchDialogOutcome(cancelled: true));
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context, SwitchDialogOutcome(error: e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('切换并重启'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _phase.label,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Builder(
              builder: (ctx) => Text(
                _message.isEmpty ? _phase.label : _message,
                style: TextStyle(fontSize: 12, color: ZcodeTokens.of(ctx).mutedForeground),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_phase == SwitchPhase.done) return;
            _cancelled = true;
            Navigator.pop(context, const SwitchDialogOutcome(cancelled: true));
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}
