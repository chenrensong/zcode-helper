import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zcode_helper/services/oauth_service.dart';

void main() {
  group('buildAuthorizeUrl', () {
    test('zai 走 relay + chat.z.ai/auth', () {
      final s = OAuthService();
      final url = s.buildAuthorizeUrl(
        'st-1234567890abcdef',
        'zai',
        callbackUri: 'http://127.0.0.1:45678/callback',
      );
      expect(url, startsWith('https://chat.z.ai/auth?'));
      final u = Uri.parse(url);
      expect(u.queryParameters['response_type'], 'code');
      expect(u.queryParameters['client_id'], OAuthService.appId);
      expect(u.queryParameters['state'], 'st-1234567890abcdef');
      final redirect = u.queryParameters['redirect_uri'];
      expect(redirect, contains('https://zcode.z.ai/app/oauth/login'));
      expect(redirect, contains('redirect='));
      if (redirect != null) {
        final decoded = Uri.decodeComponent(redirect);
        expect(decoded, contains('127.0.0.1:45678'));
        // 与 Electron oauth.js 一致：relay 的 redirect 参数值 = 内层再编码的回调地址
        final inner = Uri.parse(decoded).queryParameters['redirect'];
        expect(inner, 'http://127.0.0.1:45678/callback');
      }
    });

    test('bigmodel 走 bigmodel.cn/login + appId=zcode', () {
      final s = OAuthService();
      final url = s.buildAuthorizeUrl(
        'st-bm',
        'bigmodel',
        callbackUri: 'http://127.0.0.1:45679/callback',
      );
      expect(url, startsWith('https://bigmodel.cn/login?'));
      final u = Uri.parse(url);
      expect(u.queryParameters['appId'], 'zcode');
      expect(u.queryParameters['state'], 'st-bm');
      final redirect = u.queryParameters['redirect'];
      expect(redirect, contains('https://zcode.z.ai/app/oauth/login'));
    });

    // 与 Electron oauthCli.js 逐字节一致（用 node 实际生成核对过），
    // 中转页只接受 redirect=zcode://oauth/callback，任何偏差都会渲染
    // “无法打开 ZCode”错误页。
    test('默认回调与 Electron oauthCli.js 生成的 URL 逐字节一致', () {
      final s = OAuthService();
      expect(
        s.buildAuthorizeUrl('deadbeef01', 'zai'),
        'https://chat.z.ai/auth?response_type=code&client_id=client_P8X5CMWmlaRO9gyO-KSqtg'
        '&redirect_uri=https%3A%2F%2Fzcode.z.ai%2Fapp%2Foauth%2Flogin%3Fredirect%3D'
        'zcode%253A%252F%252Foauth%252Fcallback&state=deadbeef01',
      );
      expect(
        s.buildAuthorizeUrl('deadbeef01', 'bigmodel'),
        'https://bigmodel.cn/login?redirect=https%3A%2F%2Fzcode.z.ai%2Fapp%2Foauth%2F'
        'login%3Fredirect%3Dzcode%253A%252F%252Foauth%252Fcallback&appId=zcode&state=deadbeef01',
      );
    });
  });

  group('exchangeCode', () {
    test('zai 响应形状 → OAuthTokenSet，请求体对齐 Electron', () async {
      String? sentBody;
      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/api/v1/oauth/token')) {
          sentBody = req.body;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'token': 'zw-platform-token',
                'zai': {'access_token': 'at-zai-1', 'refresh_token': 'rt-zai-1'},
                'user': {'email': 'a@b.c', 'nickName': 'AB'},
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });
      final tokenSet = await OAuthService(client: mock).exchangeCode('cc-1', 'st-1', 'zai');
      expect(tokenSet.token, 'zw-platform-token');
      expect(tokenSet.zaiAccessToken, 'at-zai-1');
      expect(tokenSet.refreshToken, 'rt-zai-1');
      expect(tokenSet.user['email'], 'a@b.c');

      final body = jsonDecode(sentBody!) as Map<String, dynamic>;
      expect(body['provider'], 'zai');
      expect(body['code'], 'cc-1');
      expect(body['state'], 'st-1');
      expect(body['redirect_uri'], 'zcode://oauth/callback');
    });

    test('bigmodel 响应形状 + 用户信息补拉 getCustomerInfo（无 Bearer）', () async {
      var fetchCount = 0;
      String? fetchAuthHeader;
      final mock = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/api/v1/oauth/token')) {
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'token': 'zw-bm-token',
                'bigmodel': {'access_token': 'bm-at-1', 'refresh_token': 'bm-rt-1'},
                'user': <String, dynamic>{},
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/getCustomerInfo')) {
          fetchCount++;
          fetchAuthHeader = req.headers['authorization'];
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'email': 'bm@x.cn',
                'name': '模型用户',
                'customerNumber': '1234567890',
              },
            }),
            200,
            // 显式 utf-8：http.Response 默认 latin1 编码无法容纳中文 body
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });
      final tokenSet = await OAuthService(client: mock).exchangeCode('cc-2', 'st-2', 'bigmodel');
      expect(tokenSet.token, 'zw-bm-token');
      expect(tokenSet.zaiAccessToken, 'bm-at-1');
      expect(tokenSet.refreshToken, 'bm-rt-1');
      expect(fetchCount, 1);
      // 无 Bearer 前缀，与 Electron oauthCli.js 一致
      expect(fetchAuthHeader, 'bm-at-1');
      expect(tokenSet.user['email'], 'bm@x.cn');
    });

    test('zai 错误码 → OAuthException（带服务端 message）', () async {
      final mock = MockClient(
        (req) async => http.Response(jsonEncode({'code': 40002, 'message': 'bad code'}), 200),
      );
      await expectLater(
        OAuthService(client: mock).exchangeCode('bad', 'st', 'zai'),
        throwsA(isA<OAuthException>()
            .having((e) => e.message, 'message', allOf(contains('bad code')))),
      );
    });

    test('bigmodel 非 0/200 错误码 → OAuthException', () async {
      final mock = MockClient(
        (req) async => http.Response(jsonEncode({'code': 50001, 'msg': 'expired'}), 200),
      );
      await expectLater(
        OAuthService(client: mock).exchangeCode('bad', 'st', 'bigmodel'),
        throwsA(isA<OAuthException>().having((e) => e.message, 'message', contains('expired'))),
      );
    });

    test('缺少 data.token → OAuthException', () async {
      final mock = MockClient((req) async => http.Response(jsonEncode({'code': 0, 'data': {}}), 200));
      await expectLater(
        OAuthService(client: mock).exchangeCode('cc', 'st', 'zai'),
        throwsA(isA<OAuthException>()),
      );
    });

    test('服务端不响应 → 超时抛可读错误', () async {
      // 永不完成的 client 模拟网络挂起；注入 50ms 短超时加快测试。
      final never = MockClient((req) => Completer<http.Response>().future);
      await expectLater(
        OAuthService(client: never, timeout: const Duration(milliseconds: 50))
            .exchangeCode('cc', 'st', 'zai'),
        throwsA(
            isA<OAuthException>().having((e) => e.message, 'message', contains('网络超时'))),
      );
    });

    test('业务登录超时 → null（登录不中断）', () async {
      final never = MockClient((req) => Completer<http.Response>().future);
      final jwt = await OAuthService(client: never, timeout: const Duration(milliseconds: 50))
          .exchangeBusinessToken('at-x');
      expect(jwt, isNull);
    });
  });

  group('exchangeBusinessToken', () {
    test('发业务登录请求并取回业务 JWT', () async {
      String? sentBody;
      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/z/login')) {
          sentBody = req.body;
          return http.Response(
            jsonEncode({'code': 0, 'data': {'access_token': 'biz-jwt-1'}}),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final jwt = await OAuthService(client: mock).exchangeBusinessToken('at-zai-1');
      expect(jwt, 'biz-jwt-1');
      expect((jsonDecode(sentBody!) as Map<String, dynamic>)['token'], 'at-zai-1');
    });

    test('失败返回 null（登录不中断）', () async {
      final mock = MockClient((req) async => http.Response('boom', 500));
      final jwt = await OAuthService(client: mock).exchangeBusinessToken('at-x');
      expect(jwt, isNull);
    });
  });
}
