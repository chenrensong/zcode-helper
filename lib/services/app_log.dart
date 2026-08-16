import 'dart:io';

import 'package:path/path.dart' as p;

/// 诊断日志：追加到 ~/Library/Logs/zcode-helper.log（与原生侧 bridge 同文件）。
/// 失败静默——日志不应影响主流程；flutter test 环境下不写（避免污染真实日志）。
void appLog(String tag, String message) {
  if (Platform.environment['FLUTTER_TEST'] == 'true') return;
  try {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null || home.isEmpty) return;
    final logs = Directory(
      Platform.isWindows
          ? p.join(home, 'AppData', 'Local', 'zcode-helper', 'Logs')
          : p.join(home, 'Library', 'Logs'),
    );
    if (!logs.existsSync()) logs.createSync(recursive: true);
    File(p.join(logs.path, 'zcode-helper.log')).writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] [$tag] $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
