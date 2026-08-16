import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/paths.dart';

/// 应用设置：外观模式（跟随系统 / 浅色 / 深色），持久化到 zcasRoot/settings.json。
class SettingsStore extends ValueNotifier<ThemeMode> {
  SettingsStore(this.paths) : super(_load(paths));

  final AppPaths paths;

  File get _file => File(p.join(paths.zcasRoot, 'settings.json'));

  static ThemeMode _load(AppPaths paths) {
    try {
      final raw =
          jsonDecode(File(p.join(paths.zcasRoot, 'settings.json')).readAsStringSync())
              as Map<String, dynamic>;
      return switch (raw['themeMode'] as String?) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      return ThemeMode.system;
    }
  }

  @override
  set value(ThemeMode mode) {
    if (mode == value) return;
    super.value = mode;
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({'themeMode': mode.name}));
    } catch (_) {
      // 持久化失败不影响本次会话
    }
  }
}
