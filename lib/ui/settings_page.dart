import 'package:flutter/material.dart';

import '../app.dart';
import '../core/app_info.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const PageTitle(title: '设置', subtitle: '数据目录位置与构建信息'),
        const SizedBox(height: 16),
        _Section(
          title: '外观',
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: services.settings,
            builder: (context, mode, _) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_rounded, size: 16),
                  label: Text('跟随系统'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_rounded, size: 16),
                  label: Text('浅色'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_rounded, size: 16),
                  label: Text('深色'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) => services.settings.value = selection.first,
            ),
          ),
        ),
        const _Section(
          title: '数据目录',
          child: Row(
            children: [
              Icon(Icons.lock_open_rounded, size: 16, color: ZcodePalette.success),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '直读直写 ~/.zcode/v2（与本机 Electron 工具一致），无需目录授权。',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        _Section(
          title: '登录态与数据目录',
          child: _PathList(
            rows: [
              ('ZCode 登录态目录', services.paths.zcodeV2Dir),
              ('credentials.json', services.paths.credentialsFile),
              ('config.json', services.paths.configFile),
              ('账号快照', services.paths.storeDir),
              ('切换备份（.last）', services.paths.backupDir),
              ('多开实例', services.paths.instancesDir),
            ],
          ),
        ),
        _Section(
          title: '切换行为',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Bullet('切换前自动把当前登录态备份到 ${services.paths.backupDir}，可在账号页「回滚备份」恢复。'),
              _Bullet('检测到 ZCode 运行中会自动安全退出（NSRunningApplication.terminate → pkill 兜底），写登录态后自动重启；未运行时写入后自动启动。'),
              _Bullet('BigModel 账号切换时自动标准化为 ZCode 原生 profile（v2），并在需要时派生 coding-plan 平台 key。'),
            ],
          ),
        ),
        _Section(
          title: '关于',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Bullet('ZCode Helper v$appVersion — 账号快照 / 切换 / 额度 / 多开工具（原生 Flutter 桌面版，macOS / Windows）。'),
              _Bullet('项目主页：$appRepoUrl'),
              _Bullet('磁盘格式（.zcas 快照、enc:v1 加密）与前代 Electron 实现完全兼容。'),
              _Bullet('构建：flutter build macos --release / flutter build windows --release（本机）；scripts/build_dev.sh（可选 Developer ID 签名分发）。'),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: ZcodeTokens.of(context).mutedForeground)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _PathList extends StatelessWidget {
  const _PathList({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (label, path) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: Text(label,
                      style: TextStyle(fontSize: 12, color: ZcodeTokens.of(context).mutedForeground)),
                ),
                Expanded(
                  child: SelectableText(
                    path,
                    // monospace 逻辑字体：macOS 解析为 Menlo，Windows 为 Consolas
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5, right: 8),
            child: Icon(Icons.circle, size: 5, color: ZcodePalette.brand),
          ),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12, height: 1.45, color: ZcodeTokens.of(context).mutedForeground)),
          ),
        ],
      ),
    );
  }
}
