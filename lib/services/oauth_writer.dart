import 'dart:convert';

import '../core/bigmodel_profile.dart';
import '../core/crypto.dart';
import '../core/paths.dart';
import 'fs_utils.dart';
import 'oauth_service.dart';

export '../core/bigmodel_profile.dart' show toNativeBigModelUserProfile;

/// OAuth 登录完成后的写盘逻辑（对齐 Electron 版 oauth.js）。
///
/// 由 [LoginController] 编排调用；不直接与 UI 交互。
class OAuthWriter {
  // ignore: prefer_initializing_formals
  OAuthWriter(this.paths, {String? secret}) : _secret = secret;

  final AppPaths paths;
  final String? _secret;

  /// 将 token 集合加密写入 credentials.json + config.json + setting.json。
  ///
  /// 与 Electron 版 writeOAuthCredentials 对齐：
  ///   - 清除两个 provider 的旧 OAuth 字段
  ///   - 写入当前 provider 的 token / user_info
  ///   - config.json provider 段设 enabled/baseURL/apiKey
  ///   - setting.json 设 providerFamilyDomain
  Future<void> writeCredentials({
    required OAuthTokenSet tokenSet,
    required Map<String, dynamic> userInfo,
    required String provider,
  }) async {
    final isBigModel = provider == 'bigmodel';
    final secret = _secret;
    final credentials = readJsonIfExists(paths.credentialsFile);
    final config = readJsonIfExists(paths.configFile);

    // 清除两个 provider 的 OAuth 字段
    for (final pid in ['zai', 'bigmodel']) {
      for (final suffix in ['access_token', 'refresh_token', 'user_info']) {
        credentials.remove('oauth:$pid:$suffix');
      }
    }

    // 写入 active_provider
    credentials['oauth:active_provider'] =
        await encrypt(provider, secret: secret);

    // 写入 token
    final accessToken = tokenSet.zaiAccessToken;
    if (accessToken != null && accessToken.isNotEmpty) {
      credentials['oauth:$provider:access_token'] =
          await encrypt(accessToken, secret: secret);
    }
    if (tokenSet.refreshToken != null && tokenSet.refreshToken!.isNotEmpty) {
      credentials['oauth:$provider:refresh_token'] =
          await encrypt(tokenSet.refreshToken!, secret: secret);
    }
    credentials['zcodejwttoken'] =
        await encrypt(tokenSet.token, secret: secret);
    credentials['oauth:$provider:user_info'] =
        await encrypt(jsonEncode(userInfo), secret: secret);

    atomicWrite(paths.credentialsFile, jsonEncode(credentials));

    // config.json provider 段
    if (config['provider'] is! Map) {
      config['provider'] = <String, dynamic>{};
    }
    final configApiKey = isBigModel ? tokenSet.token : (accessToken ?? tokenSet.token);
    if (configApiKey.isNotEmpty) {
      updateConfigProviders(config, provider, configApiKey);
    }
    atomicWrite(paths.configFile, const JsonEncoder.withIndent('  ').convert(config));

    // setting.json
    _writeSettingProviderFamily(provider);
  }

  /// 将派生出的平台 Key 写入 live config.json 的 coding-plan 槽位。
  void applyCodingPlanApiKey(String apiKey) {
    try {
      final config = readJsonIfExists(paths.configFile);
      final providers = config['provider'];
      if (providers is! Map) return;
      final slot = providers['builtin:bigmodel-coding-plan'];
      if (slot is Map) {
        final options = slot['options'];
        if (options is Map) {
          options['apiKey'] = apiKey;
          atomicWrite(paths.configFile,
              const JsonEncoder.withIndent('  ').convert(config));
        }
      }
    } catch (_) {}
  }

  void _writeSettingProviderFamily(String providerId) {
    try {
      final setting = readJsonIfExists(paths.settingFile);
      updateSettingProviderFamily(setting, providerId);
      atomicWrite(
          paths.settingFile, const JsonEncoder.withIndent('  ').convert(setting));
    } catch (_) {}
  }
}

/// 归一化 Z.ai OAuth 返回的 user 对象为标准 userInfo。
Map<String, dynamic> normalizeUserInfo(Map<String, dynamic> user) {
  return {
    'email': user['email'] ?? user['mail'] ?? '',
    'name': user['nickName'] ??
        user['customerName'] ??
        user['name'] ??
        user['username'] ??
        user['displayName'] ??
        '',
    'avatar': user['avatar'] ?? user['avatarUrl'] ?? user['picture'] ?? '',
    'user_id': user['user_id'] ??
        user['userId'] ??
        user['id'] ??
        user['customerNumber'] ??
        user['sub'] ??
        '',
  };
}
