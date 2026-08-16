import 'package:flutter/material.dart';

import 'core/paths.dart';
import 'platform/zcode_bridge.dart';
import 'services/account_store.dart';
import 'services/app_state.dart';
import 'services/instance_service.dart';
import 'services/login_controller.dart';
import 'services/quota_service.dart';
import 'services/settings_store.dart';
import 'services/switcher.dart';
import 'ui/accounts_page.dart';
import 'ui/instances_page.dart';
import 'ui/settings_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// 应用服务聚合。
class AppServices {
  AppServices({
    required this.paths,
    required this.platform,
    required this.store,
    required this.switcher,
    required this.quota,
    required this.instances,
    required this.state,
    required this.settings,
  });

  final AppPaths paths;
  final ZCodePlatform platform;
  final AccountStore store;
  final SwitchController switcher;
  final QuotaService quota;
  final InstanceService instances;
  final AppState state;
  final SettingsStore settings;
  LoginController? _login;

  /// OAuth 登录控制器（懒加载单例）。
  LoginController get loginController => _login ??= LoginController(
        paths: paths,
        platform: platform,
        store: store,
      );
}

class ZcodeHelperApp extends StatelessWidget {
  const ZcodeHelperApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) => MaterialApp(
        title: 'ZCode Helper',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(ZcodeTokens.light),
        darkTheme: _buildTheme(ZcodeTokens.dark),
        themeMode: services.settings.value,
        home: HomeShell(services: services),
      ),
    );
  }

  ThemeData _buildTheme(ZcodeTokens t) {
    final scheme = ColorScheme.fromSeed(
      seedColor: ZcodePalette.brand,
      brightness: t.brightness,
    ).copyWith(
      primary: ZcodePalette.brand,
      onPrimary: Colors.white,
      surface: t.card,
      onSurface: t.foreground,
      surfaceContainerHighest: t.cardSelected,
      outline: t.borderHover,
      error: ZcodePalette.error,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.background,
      dividerColor: t.border,
      cardTheme: CardThemeData(
        color: t.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surfaceHover,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.card,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: t.border),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.cardSelected,
        contentTextStyle: TextStyle(color: t.foreground),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// 三页容器（通过 [IndexedStack] 保持状态）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _navItems = [
    (Icons.swap_horiz_rounded, '账号'),
    (Icons.terminal_rounded, '实例'),
    (Icons.settings_rounded, '设置'),
  ];

  @override
  void initState() {
    super.initState();
    widget.services.state.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      AccountsPage(services: widget.services),
      InstancesPage(services: widget.services),
      SettingsPage(services: widget.services),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄窗口侧栏只留图标，把宽度让给内容区
        final wide = constraints.maxWidth >= 860;
        return Scaffold(
          body: Row(
            children: [
              _Sidebar(
                index: _index,
                expanded: wide,
                services: widget.services,
                onSelected: (i) => setState(() => _index = i),
                items: _navItems,
              ),
              Expanded(
                child: Column(
                  children: [
                    StatusHeader(services: widget.services),
                    Divider(height: 1, color: ZcodeTokens.of(context).border),
                    Expanded(child: IndexedStack(index: _index, children: pages)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 自定义侧边栏：品牌头部 + 导航项（选中指示条 + 胶囊背景）+ 底部主题快捷切换。
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.index,
    required this.expanded,
    required this.services,
    required this.onSelected,
    required this.items,
  });

  final int index;
  final bool expanded;
  final AppServices services;
  final ValueChanged<int> onSelected;
  final List<(IconData, String)> items;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    return Container(
      width: expanded ? 200.0 : 64.0,
      decoration: BoxDecoration(
        color: tokens.background,
        border: Border(right: BorderSide(color: tokens.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(expanded ? 14 : 0, 14, expanded ? 14 : 0, 12),
            child: expanded
                ? Row(
                    children: [
                      const ZcodeMark(size: 30),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('ZCode Helper',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: tokens.foreground)),
                            const SizedBox(height: 1),
                            Text('多账号管理工具', style: TextStyle(fontSize: 10, color: tokens.subtleForeground)),
                          ],
                        ),
                      ),
                    ],
                  )
                : const Center(child: ZcodeMark(size: 30)),
          ),
          Divider(height: 1, color: tokens.border),
          const SizedBox(height: 8),
          for (final (i, (icon, label)) in items.indexed)
            _SidebarItem(
              icon: icon,
              label: label,
              selected: i == index,
              expanded: expanded,
              onTap: () => onSelected(i),
            ),
          const Spacer(),
          _ThemeCycleButton(services: services, expanded: expanded),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: selected ? tokens.surfaceHover : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 38,
            padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 0),
            child: Row(
              // 折叠模式：居中图标，不画指示条
              mainAxisAlignment: expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                if (expanded) ...[
                  // 选中指示条
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      color: selected ? ZcodePalette.brand : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Icon(icon,
                    size: 19,
                    color: selected ? ZcodePalette.brand : tokens.mutedForeground),
                if (expanded) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? tokens.foreground : tokens.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部主题快捷切换：点击循环 跟随系统 → 浅色 → 深色。
class _ThemeCycleButton extends StatelessWidget {
  const _ThemeCycleButton({required this.services, required this.expanded});

  final AppServices services;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final tokens = ZcodeTokens.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: services.settings,
      builder: (context, mode, _) {
        final (icon, label) = switch (mode) {
          ThemeMode.light => (Icons.light_mode_rounded, '浅色'),
          ThemeMode.dark => (Icons.dark_mode_rounded, '深色'),
          _ => (Icons.brightness_auto_rounded, '跟随系统'),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Tooltip(
            message: '切换外观（当前：$label）',
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: () => services.settings.value = switch (mode) {
                  ThemeMode.system => ThemeMode.light,
                  ThemeMode.light => ThemeMode.dark,
                  ThemeMode.dark => ThemeMode.system,
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 17, color: tokens.mutedForeground),
                      if (expanded) ...[
                        const SizedBox(width: 10),
                        Text(label, style: TextStyle(fontSize: 12, color: tokens.mutedForeground)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
