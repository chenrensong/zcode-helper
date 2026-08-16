import 'dart:convert';

import 'package:http/http.dart' as http;

/// ZCode OAuth Authorization Code 流程（与官方 ZCode 客户端一致）。
///
/// 官方客户端配置（提取自 app.asar out/host/index.js）：
///   authorizeUrl : https://chat.z.ai/auth
///   tokenUrl     : https://zcode.z.ai/api/v1/oauth/token
///   redirectUri  : zcode://oauth/callback
///   appId        : client_P8X5CMWmlaRO9gyO-KSqtg
class OAuthService {
  OAuthService({http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client ?? http.Client();

  final http.Client _client;

  /// 单次 HTTP 请求超时。可注入短超时用于测试超时路径。
  final Duration timeout;

  static const String appId = 'client_P8X5CMWmlaRO9gyO-KSqtg';
  static const String defaultCallbackUri = 'zcode://oauth/callback';
  static const String authorizeUrl = 'https://chat.z.ai/auth';
  static const String zcodeOAuthRelay = 'https://zcode.z.ai/app/oauth/login';
  static const String tokenUrl = 'https://zcode.z.ai/api/v1/oauth/token';

  static const String bigModelAuthorizeUrl = 'https://bigmodel.cn/login';
  static const String bigModelAppId = 'zcode';
  static const String bigModelProviderId = 'bigmodel';
  static const String bigModelUserInfoUrl =
      'https://open.bigmodel.cn/api/biz/customer/getCustomerInfo';

  static const String businessLoginUrl = 'https://api.z.ai/api/auth/z/login';

  /// 拼接授权页 URL（Z.ai / BigModel 统一入口）。
  ///
  /// 默认回调 `zcode://oauth/callback`（中转页只接受该值）；
  /// [callbackUri] 仅测试用途。
  String buildAuthorizeUrl(String state, String provider, {String? callbackUri}) {
    final cb = callbackUri ?? defaultCallbackUri;
    if (provider == 'bigmodel') {
      return _buildBigModelUrl(state, cb);
    }
    return _buildZaiUrl(state, cb);
  }

  String _buildZaiUrl(String state, String callbackUri) {
    final redirectUri =
        '$zcodeOAuthRelay?redirect=${Uri.encodeComponent(callbackUri)}';
    final params = {
      'response_type': 'code',
      'client_id': appId,
      'redirect_uri': redirectUri,
      'state': state,
    };
    return '$authorizeUrl?${Uri(queryParameters: params).query}';
  }

  String _buildBigModelUrl(String state, String callbackUri) {
    final zcodeRedirect =
        '$zcodeOAuthRelay?redirect=${Uri.encodeComponent(callbackUri)}';
    final params = {
      'redirect': zcodeRedirect,
      'appId': bigModelAppId,
      'state': state,
    };
    return '$bigModelAuthorizeUrl?${Uri(queryParameters: params).query}';
  }

  /// 用授权码换取 token 集合。返回 [OAuthTokenSet]。
  Future<OAuthTokenSet> exchangeCode(String code, String state, String provider) async {
    final isBigModel = provider == 'bigmodel';
    final body = isBigModel
        ? {
            'provider': bigModelProviderId,
            'code': code,
            'redirect_uri': defaultCallbackUri,
            'state': state,
          }
        : {
            'provider': 'zai',
            'code': code,
            'redirect_uri': defaultCallbackUri,
            'state': state,
          };

    final res = await _client.post(
      Uri.parse(tokenUrl),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(
      timeout,
      // 换 token 是登录关键路径：超时必须以可读错误浮出，不能挂死登录流程。
      onTimeout: () => throw OAuthException('网络超时，请检查网络后重试'),
    );

    final json = jsonDecode(res.body) as Map<String, dynamic>;

    if (!isBigModel && json['code'] != 0) {
      throw OAuthException(
          json['message']?.toString() ?? json['msg']?.toString() ?? 'token 交换失败 HTTP ${res.statusCode}');
    }
    if (isBigModel) {
      final c = json['code'];
      if (c != null && c != 0 && c != 200) {
        throw OAuthException(
            json['msg']?.toString() ?? json['message']?.toString() ?? 'token 交换失败 HTTP ${res.statusCode}');
      }
    }

    final d = (json['data'] as Map<String, dynamic>?) ?? {};
    final token = d['token'] as String?;
    if (token == null || token.isEmpty) {
      throw OAuthException('token 响应缺少 data.token');
    }

    if (isBigModel) {
      final bm = (d['bigmodel'] as Map<String, dynamic>?) ?? d;
      final accessToken = (bm['access_token'] ?? bm['accessToken'] ??
              d['access_token'] ?? d['accessToken'] ?? '')
          .toString();
      final refreshToken =
          (bm['refresh_token'] ?? bm['refreshToken'])?.toString();

      Map<String, dynamic> user = (d['user'] as Map<String, dynamic>?) ?? {};
      if (accessToken.isNotEmpty &&
          (user['email'] == null || user['email'] == '') &&
          (user['name'] == null || user['name'] == '')) {
        user = await _fetchBigModelUserInfo(accessToken) ?? user;
      }

      return OAuthTokenSet(
        token: token,
        zaiAccessToken: accessToken,
        refreshToken: refreshToken,
        user: user,
        provider: 'bigmodel',
      );
    }

    final zai = d['zai'] as Map<String, dynamic>?;
    final zaiAccessToken =
        (zai?['access_token'] ?? zai?['accessToken'])?.toString();
    if (zaiAccessToken == null || zaiAccessToken.isEmpty) {
      throw OAuthException('token 响应缺少 data.zai.access_token');
    }

    return OAuthTokenSet(
      token: token,
      zaiAccessToken: zaiAccessToken,
      refreshToken: zai?['refresh_token']?.toString(),
      user: (d['user'] as Map<String, dynamic>?) ?? {},
      provider: 'zai',
    );
  }

  /// Z.ai business login：用 OAuth access_token 换取 business JWT。
  Future<String?> exchangeBusinessToken(String zaiAccessToken) async {
    if (zaiAccessToken.isEmpty) return null;
    try {
      final res = await _client.post(
        Uri.parse(businessLoginUrl),
        headers: {
          'content-type': 'application/json',
          'accept': 'application/json',
        },
        body: jsonEncode({'token': zaiAccessToken}),
      ).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>?;
      final data = json?['data'] as Map<String, dynamic>?;
      return (data?['access_token'] ?? data?['accessToken'])?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchBigModelUserInfo(String accessToken) async {
    try {
      final res = await _client.get(
        Uri.parse(bigModelUserInfoUrl),
        headers: {'authorization': accessToken},
      ).timeout(timeout);
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      if (json is! Map) return null;
      // 与 Electron 一致：优先 data，无 data 时回退整个响应体。
      final data = json['data'];
      return Map<String, dynamic>.from(
        data is Map ? data : json,
      );
    } catch (_) {
      return null;
    }
  }

  void close() {
    _client.close();
  }
}

class OAuthTokenSet {
  OAuthTokenSet({
    required this.token,
    required this.zaiAccessToken,
    this.refreshToken,
    this.user = const {},
    this.provider = 'zai',
  });

  final String token;
  String? zaiAccessToken;
  final String? refreshToken;
  final Map<String, dynamic> user;
  final String provider;
}

class OAuthException implements Exception {
  OAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
