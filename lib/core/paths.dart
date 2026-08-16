import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用依赖的路径集合。所有确定性逻辑都通过 [AppPaths] 获取路径，
/// 便于测试用临时目录实例化。
class AppPaths {
  AppPaths({String? home, String? zcasDataDir})
      : home = home ??
            Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.',
        zcasDataDir =
            zcasDataDir ?? Platform.environment['ZCAS_DATA_DIR'];

  String get zcodeV2Dir => p.join(home, '.zcode', 'v2');

  String get credentialsFile => p.join(zcodeV2Dir, 'credentials.json');
  String get configFile => p.join(zcodeV2Dir, 'config.json');
  String get settingFile => p.join(zcodeV2Dir, 'setting.json');
  String get codingPlanCacheFile => p.join(zcodeV2Dir, 'coding-plan-cache.json');

  /// 本机是否已有 ZCode 登录态文件。
  bool get hasLoginFiles =>
      File(credentialsFile).existsSync() && File(configFile).existsSync();

  /// 本应用自己的数据根（账号快照、实例元数据、备份）。
  String get zcasRoot => zcasDataDir ?? p.join(home, '.zcas');
  String get storeDir => p.join(zcasRoot, 'accounts');
  String get instancesMetaFile => p.join(zcasRoot, 'instances.json');
  String get instancesDir => p.join(zcasRoot, 'instances');
  String get backupDir => p.join(zcasRoot, '.last');

  /// 实例根目录（元数据 + 数据）。
  String instanceRoot(String id) => p.join(instancesDir, _safeInstanceId(id));

  /// 实例专用数据目录（登录态、缓存）。
  String instanceDataRoot(String id) => p.join(instanceRoot(id), 'data');

  static String _safeInstanceId(String id) {
    final normalized = id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return normalized.isEmpty ? 'inst' : normalized;
  }

  final String home;
  final String? zcasDataDir;

  /// 查找 ZCode 可执行文件（候选与 Electron 版 paths.js 对齐）。
  String? findZCodeExe() {
    final List<String> candidates;
    if (Platform.isWindows) {
      final env = Platform.environment;
      final programFiles = env['ProgramFiles'] ?? r'C:\Program Files';
      final programFilesX86 =
          env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
      final localAppData =
          env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local');
      candidates = [
        p.join(programFiles, 'ZCode', 'ZCode.exe'),
        p.join(programFilesX86, 'ZCode', 'ZCode.exe'),
        p.join(localAppData, 'Programs', 'ZCode', 'ZCode.exe'),
        r'D:\Program Files\ZCode\ZCode.exe',
      ];
    } else {
      candidates = [
        '/Applications/ZCode.app/Contents/MacOS/ZCode',
        p.join(home, 'Applications', 'ZCode.app', 'Contents', 'MacOS', 'ZCode'),
      ];
    }
    for (final c in candidates) {
      try {
        if (File(c).existsSync()) return c;
      } catch (_) {}
    }
    return null;
  }
}
