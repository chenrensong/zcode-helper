import 'dart:convert';

import 'package:http/http.dart' as http;

/// BigModel Coding Plan 平台 API Key 派生（与 ZCode 客户端一致）。
///
/// 流程：
/// 1. GET /api/biz/customer/getCustomerInfo → 默认机构/项目
/// 2. GET/POST api_keys → 找/建 `zcode-api-key`
/// 3. GET api_keys/copy/`<apiKey>` → secretKey
/// 4. 返回 `${apiKey}.${secretKey}`
class BigModelKeyService {
  BigModelKeyService({
    http.Client? client,
    this.baseUrl = 'https://open.bigmodel.cn',
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  /// 单次 HTTP 请求超时（key 派生失败只降级为无 coding-plan key，
  /// 但不能让登录流程无限挂起）。可注入短超时用于测试。
  final Duration timeout;
  static const String apiKeyName = 'zcode-api-key';
  static const String defaultOrgName = '默认机构';
  static const String defaultProjectName = '默认项目';

  Map<String, String> _headers(String auth) => {
        'Authorization': auth,
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>?> _getJson(String url, String auth) async {
    try {
      final res = await _client
          .get(Uri.parse(url), headers: _headers(auth))
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic> ? decoded : (decoded is Map ? Map<String, dynamic>.from(decoded) : null);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _unwrapData(Map<String, dynamic> json) async {
    // 与 Electron unwrapBizJson 一致：code 非 0/200 → null；否则 data ?? 整个 json。
    final code = json['code'];
    if (code != null && code != 0 && code != 200) return null;
    final data = json['data'];
    return Map<String, dynamic>.from(data is Map ? data : json);
  }

  Future<String?> resolveBigModelCodingPlanApiKey(String accessToken) async {
    if (accessToken.isEmpty) return null;

    final info = await _getJson('$baseUrl/api/biz/customer/getCustomerInfo', accessToken);
    final unwrapped = await _unwrapData(info ?? {});
    final orgs = unwrapped?['organizations'];

    Object? org;
    if (orgs is List) {
      for (final o in orgs) {
        if (o is Map && (o['organizationName'] ?? '').toString().contains(defaultOrgName)) {
          org = o;
          break;
        }
      }
      org ??= orgs.isEmpty ? null : orgs.first;
    }
    final orgMap = org is Map ? Map<String, dynamic>.from(org) : null;
    final orgId = orgMap?['organizationId']?.toString() ?? '';
    if (orgId.isEmpty) return null;

    final projects = (orgMap?['projects'] is List) ? orgMap!['projects'] as List : const [];
    Object? proj;
    for (final pr in projects) {
      if (pr is Map && (pr['projectName'] ?? '').toString().contains(defaultProjectName)) {
        proj = pr;
        break;
      }
    }
    proj ??= projects.isEmpty ? null : projects.first;
    final projMap = proj is Map ? Map<String, dynamic>.from(proj) : null;
    final projectId = projMap?['projectId']?.toString() ?? '';
    if (projectId.isEmpty) return null;

    final keysUrl = '$baseUrl/api/biz/v1/organization/$orgId/projects/$projectId/api_keys';

    Map<String, dynamic>? entry;
    final listJson = await _getJson(keysUrl, accessToken);
    if (listJson != null) {
      final data = listJson['data'];
      final items = (data is List) ? data : const [];
      for (final k in items) {
        if (k is Map && k['name'] == apiKeyName) {
          entry = Map<String, dynamic>.from(k);
          break;
        }
      }
    }

    if (entry == null) {
      try {
        final res = await _client
            .post(Uri.parse(keysUrl),
                headers: _headers(accessToken), body: jsonEncode({'name': apiKeyName}))
            .timeout(timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            final data = decoded['data'];
            if (data is Map) entry = Map<String, dynamic>.from(data);
          }
        }
      } catch (_) {
        return null;
      }
    }

    final apiKey = (entry?['apiKey'] ?? '').toString().trim();
    if (apiKey.isEmpty) return null;

    final copyJson = await _getJson('$keysUrl/copy/${Uri.encodeComponent(apiKey)}', accessToken);
    final secretKey = (copyJson?['data'] is Map
            ? (copyJson!['data'] as Map)['secretKey']
            : copyJson?['secretKey'] ?? '')
        .toString()
        .trim();
    return secretKey.isEmpty ? null : '$apiKey.$secretKey';
  }
}
