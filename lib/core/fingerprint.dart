import 'dart:convert';
import 'dart:io';

import 'crypto.dart';
import 'jwt.dart';

/// 稳定 10 位十六进制短哈希（用于弱指纹去重，非安全用途）。
String _shortHash10(String input) {
  final h = simpleHash(input);
  if (h.length >= 10) return h.substring(0, 10);
  return h.padLeft(10, '0');
}

/// 从当前登录态文件提取的账号指纹（与 Electron 工具同构）。
class Fingerprint {
  const Fingerprint({
    required this.userId,
    required this.shortId,
    required this.emailShortId,
    required this.provider,
    required this.label,
    this.email,
    this.name,
    this.avatar,
    this.customerId,
    this.userKey,
    this.source,
  });

  final String userId;
  final String shortId;
  final String emailShortId;
  final String provider;
  final String label;
  final String? email;
  final String? name;
  final String? avatar;
  final String? customerId;
  final String? userKey;
  final String? source;
}

/// 读取凭据文件中的用户资料（解密 user_info + access token payload）。
Future<Map<String, dynamic>?> readCredentialProfile(
  String credentialsFile, {
  String? secret,
}) async {
  try {
    final raw = jsonDecode(File(credentialsFile).readAsStringSync());
    if (raw is! Map) return null;
    final cred = raw;
    final activeProviderRaw = cred['oauth:active_provider'];
    final activeProvider =
        (await safeDecrypt(activeProviderRaw, secret: secret)) ?? 'zai';

    final userInfoRaw = cred['oauth:$activeProvider:user_info'];
    final userInfo = await decryptJson(userInfoRaw, secret: secret);
    final accessTokenRaw = cred['oauth:$activeProvider:access_token'];
    var accessPayload = <String, dynamic>{};
    final at = await safeDecrypt(accessTokenRaw, secret: secret);
    if (at != null) accessPayload = decodeJwt(at) ?? {};

    return {
      'activeProvider': activeProvider,
      'email': userInfo is Map ? userInfo['email'] : null,
      'name': userInfo is Map
          ? (userInfo['name'] ?? userInfo['username'] ?? userInfo['displayName'])
          : null,
      'avatar': userInfo is Map ? userInfo['avatar'] : null,
      'credentialUserId': userInfo is Map ? userInfo['user_id'] : null,
      'customerId': accessPayload['customer_id'],
      'accessUserId': accessPayload['user_id'] ?? accessPayload['sub'],
      'userKey': accessPayload['user_key'],
    };
  } catch (_) {
    return null;
  }
}

/// 从明确的 credentials/config 文件提取账号指纹（可为任意实例目录）。
Future<Fingerprint?> extractFingerprint({
  required String credentialsFile,
  required String configFile,
  String? secret,
}) async {
  final profile = (await readCredentialProfile(credentialsFile, secret: secret)) ?? const <String, dynamic>{};

  // 1. 从 config.json 找启用中且带 apiKey 的 provider
  try {
    final rawCfg = jsonDecode(File(configFile).readAsStringSync());
    final providers = (rawCfg is Map && rawCfg['provider'] is Map)
        ? (rawCfg['provider'] as Map)
        : <String, dynamic>{};
    final candidates = <Map<String, dynamic>>[];
    for (final entry in providers.entries) {
      final p = entry.value;
      if (p is! Map) continue;
      final options = p['options'];
      if (options is! Map) continue;
      final apiKey = options['apiKey'];
      if (apiKey is! String || apiKey.isEmpty) continue;
      if (apiKey.startsWith('enc:') || apiKey.length < 30) continue;
      candidates.add({
        'id': entry.key,
        'enabled': p['enabled'] == true,
        'apiKey': apiKey,
      });
    }
    candidates.sort((a, b) {
      final ae = a['enabled'] == true ? 1 : 0;
      final be = b['enabled'] == true ? 1 : 0;
      return be - ae;
    });

    for (final c in candidates) {
      final payload = decodeJwt(c['apiKey'] as String);
      if (payload == null) continue;
      // zai 槽位 JWT 的 user_id 是数字（Electron 版直接采用），必须归一化为
      // 字符串再比较，否则会跳过 zai 槽、误中残留的 bigmodel-start-plan
      // 平台 JWT，把 Z.ai 账号标成 bigmodel。
      final uidRaw = payload['user_id'] ?? payload['sub'];
      final uid = uidRaw is String
          ? uidRaw
          : uidRaw is num
              ? uidRaw.toString()
              : null;
      if (uid == null || uid.isEmpty) continue;
      final shortId = uid.length >= 8 ? uid.substring(0, 8) : uid;
      final email = profile['email'] is String ? profile['email'] as String : null;
      final emailShortId = email != null && email.isNotEmpty
          ? 'em-${_shortHash10(email.toLowerCase())}'
          : shortId;
      return Fingerprint(
        userId: uid,
        shortId: shortId,
        emailShortId: emailShortId,
        provider: c['id'] as String,
        label: (email != null && email.isNotEmpty) ? email : (profile['name'] ?? '账号-$shortId') as String,
        email: email,
        name: profile['name'] as String?,
        avatar: profile['avatar'] as String?,
        customerId: profile['customerId'] as String?,
        userKey: profile['userKey'] as String?,
        source: email != null && email.isNotEmpty
            ? 'config.jwt+credentials.user_info'
            : 'config.jwt',
      );
    }
  } catch (_) {}

  // 2. 兜底：从凭据加密字段取指纹（弱指纹，仅去重）
  try {
    final raw = jsonDecode(File(credentialsFile).readAsStringSync());
    if (raw is! Map) return null;
    final cred = raw;
    final apRaw = cred['oauth:active_provider'];
    final ap = apRaw is String ? apRaw : '';
    final hash = simpleHash(ap);
    final shortId = hash.length >= 8 ? hash.substring(0, 8) : hash;
    final email = profile['email'] is String ? profile['email'] as String : null;
    final emailShortId = email != null && email.isNotEmpty
        ? 'em-${_shortHash10(email.toLowerCase())}'
        : shortId;
    final userId = (profile['credentialUserId'] ?? profile['accessUserId'] ?? 'enc-$hash') as String;
    final label = (email != null && email.isNotEmpty)
        ? email
        : (profile['name'] ?? '账号-$shortId') as String;
    return Fingerprint(
      userId: userId,
      shortId: shortId,
      emailShortId: emailShortId,
      provider: profile['activeProvider'] is String ? profile['activeProvider'] as String : '(encrypted)',
      label: label,
      email: email,
      name: profile['name'] as String?,
      avatar: profile['avatar'] as String?,
      customerId: profile['customerId'] as String?,
      userKey: profile['userKey'] as String?,
      source: email != null && email.isNotEmpty ? 'credentials.user_info' : 'credentials.fallback',
    );
  } catch (_) {
    return null;
  }
}
