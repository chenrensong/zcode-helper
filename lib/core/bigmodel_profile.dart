library;

import 'core.dart' show firstText;

/// ZCode 客户端 provider 配置与 BigModel 原生 cached-profile 契约。
///
/// 逆向自 Electron 工具与 ZCode app.asar：BigModel 的 `oauth:bigmodel:user_info`
/// 必须是 `{id, username, displayName, rawProfile.zcodeProfileSchemaVersion:2}`
/// 结构，通用 `{email,name,avatar,user_id}` 只在 Z.ai 可用。

class ProviderSpec {
  const ProviderSpec({
    required this.enabled,
    this.baseURL,
    this.withApiKey = false,
  });

  final bool enabled;
  final String? baseURL;

  /// true=写入 apiKey；false=删除 apiKey；'clear'=置空字符串。
  final Object withApiKey;
}

const Map<String, Map<String, ProviderSpec>> kProviders = {
  'zai': {
    'builtin:zai': ProviderSpec(enabled: true, baseURL: 'https://api.z.ai/api/anthropic', withApiKey: true),
    'builtin:zai-coding-plan': ProviderSpec(enabled: true, baseURL: 'https://api.z.ai/api/anthropic', withApiKey: true),
    'builtin:zai-start-plan': ProviderSpec(enabled: true, baseURL: 'https://zcode.z.ai/api/v1/zcode-plan/anthropic', withApiKey: true),
  },
  'bigmodel': {
    'builtin:bigmodel': ProviderSpec(enabled: true, baseURL: 'https://open.bigmodel.cn/api/anthropic', withApiKey: false),
    'builtin:bigmodel-coding-plan': ProviderSpec(enabled: true, baseURL: 'https://open.bigmodel.cn/api/anthropic', withApiKey: 'clear'),
    'builtin:bigmodel-start-plan': ProviderSpec(enabled: false, baseURL: 'https://zcode.z.ai/api/v1/zcode-plan/anthropic', withApiKey: true),
  },
};

const List<String> kAllProviderIds = [
  'builtin:zai',
  'builtin:zai-coding-plan',
  'builtin:zai-start-plan',
  'builtin:bigmodel',
  'builtin:bigmodel-coding-plan',
  'builtin:bigmodel-start-plan',
];

/// 将 provider 配置写入 config.json 的 provider 段（纯操作，返回新的 config map）。
/// 与 Electron 工具 `updateConfigProviders` 行为一致。
Map<String, dynamic> updateConfigProviders(
  Map<String, dynamic> config,
  String provider,
  String? apiKey,
) {
  final providerCfg = kProviders[provider] ?? kProviders['zai']!;
  final providers = config['provider'];
  final providerMap = (providers is Map) ? Map<String, dynamic>.from(providers) : <String, dynamic>{};
  config['provider'] = providerMap;

  providerCfg.forEach((id, spec) {
    providerMap[id] ??= <String, dynamic>{'options': <String, dynamic>{}};
    final entry = providerMap[id]!;
    entry['options'] ??= <String, dynamic>{};
    final options = entry['options']!;
    entry['enabled'] = spec.enabled;
    final mode = spec.withApiKey;
    if (mode == true && apiKey != null && apiKey.isNotEmpty) {
      options['apiKey'] = apiKey;
    } else if (mode == false) {
      options.remove('apiKey');
    } else if (mode == 'clear') {
      options['apiKey'] = '';
    }
    if (spec.baseURL != null) options['baseURL'] = spec.baseURL;
  });

  // 对向 provider 全部禁用
  for (final id in kAllProviderIds) {
    if (providerCfg.containsKey(id)) continue;
    if (providerMap[id] is Map) {
      (providerMap[id] as Map)['enabled'] = false;
    }
  }
  return config;
}

/// 生成 setting.json 的 providerFamilyDomain 段（纯操作，返回新的 setting map）。
Map<String, dynamic> updateSettingProviderFamily(Map<String, dynamic> setting, String providerId) {
  setting['providerFamilyDomain'] = providerId;
  setting['providerFamilyDomainUpdatedAt'] = DateTime.now().millisecondsSinceEpoch;
  setting['providerFamilyDomainMigrated'] = true;
  final modes = setting['modelProviderFamilyModes'];
  final modeMap = (modes is Map) ? Map<String, dynamic>.from(modes) : <String, dynamic>{};
  modeMap[providerId] = 'oauth';
  setting['modelProviderFamilyModes'] = modeMap;
  return setting;
}

/// 将 BigModel customer-info 映射为 ZCode 原生 cached-profile。
Map<String, dynamic> toNativeBigModelUserProfile(Object? user) {
  final u = user is Map ? Map<String, dynamic>.from(user) : <String, dynamic>{};
  final id = firstText([
    u['customerNumber'],
    u['customerId'],
    u['user_id'],
    u['userId'],
    u['id'],
    u['sub'],
  ]) ?? 'unknown';
  final name = firstText([
    u['customerName'],
    u['nickName'],
    u['name'],
    u['username'],
    u['displayName'],
    u['email'],
    u['mail'],
  ]);
  final isFallback = id == 'unknown' && (name == null || name.isEmpty);
  final avatarUrl = firstText([u['avatar'], u['avatarUrl'], u['picture']]);
  final rawProfileRaw = u['rawProfile'];
  final rawProfile = (rawProfileRaw is Map)
      ? Map<String, dynamic>.from(rawProfileRaw)
      : <String, dynamic>{};

  return {
    'id': id,
    'username': (name != null && name.isNotEmpty) ? name : 'user',
    'displayName': (name != null && name.isNotEmpty)
        ? name
        : (isFallback ? 'User' : id),
    'avatarUrl': ?avatarUrl,
    'rawProfile': {...rawProfile, 'zcodeProfileSchemaVersion': 2},
  };
}

bool isNativeBigModelUserProfile(Object? user) {
  return user is Map &&
      user['id'] is String &&
      user['username'] is String &&
      user['displayName'] is String;
}

/// 旧版通用资料 -> BigModel 原生结构；原生资料保持原样。
Map<String, dynamic> normalizeBigModelUserProfile(Object? user) {
  return isNativeBigModelUserProfile(user)
      ? Map<String, dynamic>.from(user as Map)
      : toNativeBigModelUserProfile(user);
}
