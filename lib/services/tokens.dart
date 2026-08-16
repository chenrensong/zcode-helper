import 'dart:convert';
import 'dart:io';

import '../core/account_models.dart';
import '../core/crypto.dart';

/// token 候选提取（顺序即优先级）：
/// zcodejwttoken 最前（billing 正确 token），其后为 OAuth access_token 与
/// config.json 中的 provider apiKey。
Future<List<String>> readCandidateTokensFromMaps({
  required Map<String, dynamic> credentials,
  required Map<String, dynamic> config,
  String? secret,
}) async {
  final activeProvider =
      (await safeDecrypt(credentials['oauth:active_provider'], secret: secret)) ?? 'zai';
  final tokens = <String>[];
  Future<void> add(Object? value) async {
    final plain = await safeDecrypt(value, secret: secret);
    if (plain != null && plain.trim().length > 20 && !tokens.contains(plain)) {
      tokens.add(plain);
    }
  }

  await add(credentials['zcodejwttoken']);
  await add(credentials['oauth:zai:access_token']);
  await add(credentials['oauth:bigmodel:access_token']);
  await add(credentials['oauth:$activeProvider:access_token']);

  final providers = config['provider'];
  if (providers is Map) {
    for (final p in providers.values) {
      if (p is! Map) continue;
      final options = p['options'];
      if (options is! Map) continue;
      final apiKey = options['apiKey'];
      if (apiKey is String && apiKey.trim().length > 20 && !tokens.contains(apiKey)) {
        tokens.add(apiKey);
      }
    }
  }
  return tokens;
}

Future<List<String>> readCandidateTokensFromSnapshot(
  Snapshot? snapshot, {
  String? secret,
}) async {
  if (snapshot == null) return const [];
  try {
    final c = jsonDecode(snapshot.credentials) as Map<String, dynamic>;
    final g = jsonDecode(snapshot.config) as Map<String, dynamic>? ?? {};
    return await readCandidateTokensFromMaps(credentials: c, config: g, secret: secret);
  } catch (_) {
    return const [];
  }
}

Future<List<String>> readCandidateTokensFromFiles(
  String credentialsFile,
  String configFile, {
  String? secret,
}) async {
  try {
    final c = jsonDecode(File(credentialsFile).readAsStringSync()) as Map<String, dynamic>;
    Map<String, dynamic> g;
    try {
      g = jsonDecode(File(configFile).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      g = {};
    }
    return await readCandidateTokensFromMaps(credentials: c, config: g, secret: secret);
  } catch (_) {
    return const [];
  }
}

/// 从快照中检测 provider（zai / bigmodel）。
Future<String?> detectProviderFromSnapshot(Snapshot? snapshot, {String? secret}) async {
  if (snapshot == null) return 'zai';
  try {
    final c = jsonDecode(snapshot.credentials) as Map<String, dynamic>;
    final ap = await safeDecrypt(c['oauth:active_provider'], secret: secret);
    return (ap == null || ap.isEmpty) ? 'zai' : ap;
  } catch (_) {
    return 'zai';
  }
}
