import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 原子写入：先写 `.tmp` 再 rename。
void atomicWrite(String filePath, String content) {
  final dir = p.dirname(filePath);
  Directory(dir).createSync(recursive: true);
  final tmp = '$filePath.zcas.tmp';
  File(tmp).writeAsStringSync(content, flush: true);
  File(tmp).renameSync(filePath);
}

Map<String, dynamic> readJsonIfExists(String filePath, {Map<String, dynamic> fallback = const {}}) {
  try {
    if (!File(filePath).existsSync()) return Map.of(fallback);
    final decoded = jsonDecode(File(filePath).readAsStringSync());
    return (decoded is Map && decoded is! List)
        ? Map<String, dynamic>.from(decoded)
        : Map.of(fallback);
  } catch (_) {
    return Map.of(fallback);
  }
}

void writeJsonPretty(String filePath, Map<String, dynamic> data) {
  atomicWrite(filePath, const JsonEncoder.withIndent('  ').convert(data));
}
