import 'dart:convert';

import '../core/account_models.dart';
import '../core/crypto.dart';
import '../core/jwt.dart';
import 'tokens.dart';

/// 静态快照健康检查（不访问网络）。结果映射为 [AccountHealth]。
Future<AccountHealth> validateSnapshot(
  Snapshot? snapshot, {
  AccountMeta? meta,
  String? secret,
}) async {
  final details = <String, dynamic>{
    'hasCredentials': false,
    'hasConfig': false,
    'canParseCredentials': false,
    'canParseConfig': false,
    'hasTokens': false,
    'canDecryptUserInfo': false,
    'hasProviderApiKey': false,
    'userId': meta?.userId,
    'provider': meta?.provider,
  };
  final warnings = <String>[];
  final errors = <String>[];

  if (snapshot == null) {
    return _finalize(details, warnings, ['账号快照不存在或格式不正确']);
  }

  final hasCredentials = snapshot.credentials.trim().isNotEmpty;
  final hasConfig = snapshot.config.trim().isNotEmpty;
  details['hasCredentials'] = hasCredentials;
  details['hasConfig'] = hasConfig;
  if (!hasCredentials) errors.add('缺少 credentials 登录态');
  if (!hasConfig) errors.add('缺少 config 登录态');
  if (!hasCredentials || !hasConfig) return _finalize(details, warnings, errors);

  Map<String, dynamic>? credentials;
  Map<String, dynamic>? config;
  try {
    credentials = jsonDecode(snapshot.credentials) as Map<String, dynamic>;
    details['canParseCredentials'] = true;
  } catch (_) {
    errors.add('credentials.json 不是有效 JSON');
  }
  try {
    config = jsonDecode(snapshot.config) as Map<String, dynamic>;
    details['canParseConfig'] = true;
  } catch (_) {
    errors.add('config.json 不是有效 JSON');
  }
  if (credentials == null || config == null) {
    return _finalize(details, warnings, errors, properties: credentials ?? {}, config: config ?? {});
  }

  final tokens = await readCandidateTokensFromMaps(credentials: credentials, config: config, secret: secret);
  details['hasTokens'] = tokens.isNotEmpty;
  if (tokens.isEmpty) errors.add('未找到可用于登录/查询的 token');

  final providerInfo = await extractProviderInfo(credentials, config, secret: secret);
  details['provider'] = details['provider'] ?? providerInfo['provider'];
  details['hasProviderApiKey'] = providerInfo['apiKey'] != null;
  details['userId'] = details['userId'] ?? providerInfo['userId'];
  if (providerInfo['apiKey'] == null) {
    warnings.add('快照里没有启用中的 provider 配置，切换时会自动修复，不影响使用');
  }
  if (providerInfo['userId'] == null) {
    // BigModel 等账号的 config 里通常没有明文 JWT apiKey（为空或派生 key），
    // 指纹走 credentials 兜底（user_info / access token）；兜底能取到就不算异常。
    final fallbackId = await _fallbackUserId(credentials, providerInfo['provider'] as String?, secret: secret);
    if (fallbackId != null) {
      details['userId'] = fallbackId;
    } else {
      warnings.add('无法解析账号指纹，重复捕获同一账号时可能重复建卡');
    }
  }

  final userInfoState = await checkUserInfo(credentials, providerInfo['provider'] as String?, secret: secret);
  details['canDecryptUserInfo'] = userInfoState['canDecryptUserInfo'];
  if (userInfoState['warning'] != null) warnings.add(userInfoState['warning'] as String);

  return _finalize(details, warnings, errors);
}

Future<Map<String, dynamic>> extractProviderInfo(
  Map<String, dynamic> credentials,
  Map<String, dynamic> config, {
  String? secret,
}) async {
  final activeProvider = await readActiveProvider(credentials, secret: secret);
  final providers = config['provider'];
  final candidates = <Map<String, dynamic>>[];
  if (providers is Map) {
    for (final entry in providers.entries) {
      final p = entry.value;
      if (p is! Map) continue;
      final options = p['options'];
      if (options is! Map) continue;
      final apiKey = options['apiKey'];
      if (apiKey is! String || apiKey.isEmpty) continue;
      candidates.add({
        'id': entry.key,
        'enabled': p['enabled'] == true,
        'apiKey': apiKey,
        'userId': (decodeJwt(apiKey) ?? {})['user_id'],
      });
    }
  }
  candidates.sort((a, b) {
    final ae = a['enabled'] == true ? 1 : 0;
    final be = b['enabled'] == true ? 1 : 0;
    return be - ae;
  });
  final preferred = candidates.isEmpty ? null : candidates.first;
  return {
    'provider': activeProvider ?? (preferred != null ? preferred['id'] as String : null),
    'apiKey': preferred != null ? preferred['apiKey'] as String : null,
    'userId': preferred != null ? preferred['userId'] : null,
  };
}

Future<String?> readActiveProvider(Map<String, dynamic> credentials, {String? secret}) async {
  final value = credentials['oauth:active_provider'];
  if (value == null) return null;
  return safeDecrypt(value, secret: secret);
}

Future<Map<String, dynamic>> checkUserInfo(
  Map<String, dynamic> credentials,
  String? provider, {
  String? secret,
}) async {
  final keys = <String>[];
  if (provider != null) keys.add('oauth:$provider:user_info');
  keys.addAll(['oauth:zai:user_info', 'oauth:bigmodel:user_info']);
  for (final key in keys) {
    final value = credentials[key];
    if (value == null) continue;
    if (!isEncrypted(value)) return {'canDecryptUserInfo': true};
    try {
      final data = await decryptJson(value, secret: secret);
      if (data is Map) return {'canDecryptUserInfo': true};
      return {
        'canDecryptUserInfo': false,
        'warning': 'user_info 解密后格式异常，账号信息显示可能不完整',
      };
    } catch (_) {
      return {
        'canDecryptUserInfo': false,
        'warning': 'user_info 与本机密钥不匹配（可能来自其他电脑的快照），账号信息显示可能不完整',
      };
    }
  }
  return {'canDecryptUserInfo': false, 'warning': '缺少 user_info，账号信息显示不完整'};
}

/// config 无 JWT apiKey 时的指纹兜底（与 extractFingerprint 的兜底路径对齐）：
/// user_info 的 user_id（BigModel v2 profile 用 id）→ access token JWT 载荷。
Future<String?> _fallbackUserId(
  Map<String, dynamic> credentials,
  String? provider, {
  String? secret,
}) async {
  final providers = <String>{if (provider != null && provider.isNotEmpty) provider, 'zai', 'bigmodel'};
  for (final p in providers) {
    final raw = credentials['oauth:$p:user_info'];
    if (raw is! String || raw.isEmpty) continue;
    Map? info;
    if (isEncrypted(raw)) {
      try {
        info = (await decryptJson(raw, secret: secret)) as Map?;
      } catch (_) {
        info = null;
      }
    } else {
      try {
        info = jsonDecode(raw) as Map?;
      } catch (_) {
        info = null;
      }
    }
    if (info is! Map) continue;
    for (final key in const ['user_id', 'id']) {
      final uid = info[key];
      if (uid is String && uid.isNotEmpty) return uid;
    }
  }
  for (final p in providers) {
    final raw = credentials['oauth:$p:access_token'];
    if (raw is! String || raw.isEmpty) continue;
    final at = await safeDecrypt(raw, secret: secret);
    if (at == null) continue;
    final payload = decodeJwt(at);
    if (payload == null) continue;
    final uid = payload['user_id'] ?? payload['sub'];
    if (uid is String && uid.isNotEmpty) return uid;
  }
  return null;
}

AccountHealth _finalize(
  Map<String, dynamic> details,
  List<String> warnings,
  List<String> errors, {
  Map<String, dynamic>? properties,
  Map<String, dynamic>? config,
}) {
  final status = errors.isNotEmpty ? 'error' : warnings.isNotEmpty ? 'warning' : 'healthy';
  final summary = status == 'healthy'
      ? '快照完整，可正常使用'
      : status == 'warning'
          ? warnings.first
          : errors.first;
  return AccountHealth(status: status, summary: summary, warnings: warnings, errors: errors, details: details);
}
