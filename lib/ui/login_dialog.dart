import 'package:flutter/material.dart';

import '../core/account_models.dart';
import '../services/login_controller.dart';
import '../services/switcher.dart';
import 'theme.dart';

/// 选择登录渠道。
Future<String?> showProviderPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('登录账号'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('选择要登录的账号渠道：', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            _ProviderTile(
              mark: const ProviderMark(size: 38, provider: 'zai'),
              title: 'Z.ai（全球区）',
              subtitle: 'chat.z.ai / z.ai，提交界面选择 Use Z.ai Mode',
              color: ZcodePalette.zai,
              onTap: () => Navigator.pop(ctx, 'zai'),
            ),
            const SizedBox(height: 10),
            _ProviderTile(
              mark: const ProviderMark(size: 38, provider: 'bigmodel'),
              title: 'BigModel（中国区）',
              subtitle: 'bigmodel.cn，提交界面选择 China Mode',
              color: ZcodePalette.bigmodel,
              onTap: () => Navigator.pop(ctx, 'bigmodel'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
      ],
    ),
  );
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.mark,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final Widget mark;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    return Material(
      color: tokens.surfaceHover,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              mark,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 11, color: tokens.mutedForeground)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: tokens.subtleForeground),
            ],
          ),
        ),
      ),
    );
  }
}

/// 登录进度对话框：阶段提示 + 手动粘贴授权码兜底 + 取消。
Future<LoginResult?> showLoginDialog(
  BuildContext context,
  String provider,
  LoginController controller,
) {
  return showDialog<LoginResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => LoginDialog(provider: provider, controller: controller),
  );
}

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.provider, required this.controller});

  final String provider;
  final LoginController controller;

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  LoginPhase? _phase;
  String _message = '';
  String? _error;
  bool _cancelled = false;
  final TextEditingController _codeCtrl = TextEditingController();

  String get _providerName => widget.provider == 'bigmodel' ? 'BigModel' : 'Z.ai';

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      final result = await widget.controller.login(
        provider: widget.provider,
        onPhase: (phase, message) {
          if (mounted) {
            setState(() {
              _phase = phase;
              _message = message;
            });
          }
        },
        isCancelled: () => _cancelled,
      );
      if (mounted) Navigator.of(context).pop(result);
    } on SwitchAborted {
      // 用户取消（关闭 OAuth 窗口等）：静默关闭对话框，不算失败。
      if (mounted) Navigator.of(context).pop(null);
      return;
    } on SwitchError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _phase = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _phase = null;
        });
      }
    }
  }

  void _submitCode() {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) return;
    widget.controller.submitManualCode(code);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    return AlertDialog(
      title: Text('登录 $_providerName 账号'),
      content: SizedBox(
        width: 440,
        child: _error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: ZcodePalette.error),
                      const SizedBox(width: 8),
                      const Text('登录失败', style: TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    _error!,
                    style: TextStyle(fontSize: 13, color: tokens.errorMuted),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '可点击「重试」重新开始，或「取消」关闭。若多次失败，请在浏览器中复制地址栏 zcode://oauth/callback?code=... 的 code 值手动粘贴。',
                    style: TextStyle(fontSize: 11, color: tokens.subtleForeground),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _phase == null ? '正在启动…' : _phase!.label,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(_message, style: const TextStyle(fontSize: 12.5)),
                  if (_phase == LoginPhase.waiting) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: tokens.surfaceHover,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: tokens.border),
                      ),
                      child: Text(
                        '如果浏览器没有自动跳转：复制地址栏中 zcode://oauth/callback?code=xxx 的 code 值，粘贴到下方。',
                        style: const TextStyle(fontSize: 11, color: ZcodePalette.commandNode),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeCtrl,
                            decoration: const InputDecoration(
                              labelText: '授权码（code）',
                              hintText: '粘贴 code 参数值',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _submitCode(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(onPressed: _submitCode, child: const Text('提交')),
                      ],
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
        if (_error != null)
          FilledButton(
            onPressed: () async {
              _cancelled = false;
              setState(() {
                _error = null;
                _phase = null;
                _message = '';
              });
              _run();
            },
            child: const Text('重试'),
          ),
        if (_error == null)
          TextButton(
            onPressed: () {
              _cancelled = true;
            },
            child: const Text('取消'),
          ),
      ],
    );
  }
}
