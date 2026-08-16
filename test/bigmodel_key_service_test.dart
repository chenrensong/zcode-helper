import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zcode_helper/services/bigmodel_key_service.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      // 显式 utf-8：http.Response 默认 latin1 编码无法容纳中文 body
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  // getCustomerInfo 的标准响应：默认机构 + 默认项目。
  Map<String, dynamic> infoBody({
    List<Map<String, dynamic>> organizations = const [],
  }) =>
      {
        'code': 200,
        'data': {'organizations': organizations},
      };

  final defaultOrgs = [
    {
      'organizationName': '默认机构',
      'organizationId': 'org-1',
      'projects': [
        {'projectName': '默认项目', 'projectId': 'proj-1'},
      ],
    },
  ];

  test('无 organizations → null（不发起后续请求）', () async {
    final requests = <String>[];
    final mock = MockClient((req) async {
      requests.add('${req.method} ${req.url.path}');
      return _json(infoBody());
    });
    final result = await BigModelKeyService(client: mock).resolveBigModelCodingPlanApiKey('at-1');
    expect(result, isNull);
    expect(requests, hasLength(1));
  });

  test('默认机构/项目匹配（非首个机构也选中）', () async {
    final orgs = [
      {
        'organizationName': '个人机构',
        'organizationId': 'org-A',
        'projects': [
          {'projectName': '个人项目', 'projectId': 'proj-A'},
        ],
      },
      ...defaultOrgs,
    ];
    final keysUrls = <String>[];
    final mock = MockClient((req) async {
      final url = req.url.toString();
      if (url.endsWith('/getCustomerInfo')) return _json(infoBody(organizations: orgs));
      if (url.contains('/copy/')) return _json({'data': {'secretKey': 'sk-9'}});
      if (url.contains('/api_keys')) {
        keysUrls.add('${req.method} $url');
        return _json({'data': [
          {'name': 'zcode-api-key', 'apiKey': 'ak-1'}
        ]});
      }
      return _json({}, 404);
    });
    final result = await BigModelKeyService(client: mock).resolveBigModelCodingPlanApiKey('at-1');
    // 走默认机构/默认项目的 keys 端点，而不是首个机构
    expect(result, 'ak-1.sk-9');
    expect(keysUrls.single, contains('org-1'));
    expect(keysUrls.single, contains('proj-1'));
  });

  test('已存在同名 key 复用（不 POST 创建），copy 拼接 secretKey', () async {
    var postCount = 0;
    final mock = MockClient((req) async {
      final url = req.url.toString();
      if (url.endsWith('/getCustomerInfo')) return _json(infoBody(organizations: defaultOrgs));
      if (url.contains('/copy/')) return _json({'data': {'secretKey': 'sk-9'}});
      if (url.contains('/api_keys')) {
        if (req.method == 'POST') postCount++;
        return _json({'data': [
          {'name': 'zcode-api-key', 'apiKey': 'ak-1'}
        ]});
      }
      return _json({}, 404);
    });
    final result = await BigModelKeyService(client: mock).resolveBigModelCodingPlanApiKey('at-1');
    expect(result, 'ak-1.sk-9');
    expect(postCount, 0);
  });

  test('不存在同名 key → POST 创建并使用新 key', () async {
    var postCount = 0;
    String? postBody;
    final mock = MockClient((req) async {
      final url = req.url.toString();
      if (url.endsWith('/getCustomerInfo')) return _json(infoBody(organizations: defaultOrgs));
      if (url.contains('/copy/')) return _json({'data': {'secretKey': 'sk-9'}});
      if (url.contains('/api_keys')) {
        if (req.method == 'POST') {
          postCount++;
          postBody = req.body;
          return _json({'data': {'name': 'zcode-api-key', 'apiKey': 'ak-new'}}, 201);
        }
        return _json({'data': []});
      }
      return _json({}, 404);
    });
    final result = await BigModelKeyService(client: mock).resolveBigModelCodingPlanApiKey('at-1');
    expect(result, 'ak-new.sk-9');
    expect(postCount, 1);
    expect((jsonDecode(postBody!) as Map<String, dynamic>)['name'], 'zcode-api-key');
  });

  test('中途失败（keys 列表与创建均失败）→ null', () async {
    final mock = MockClient((req) async {
      final url = req.url.toString();
      if (url.endsWith('/getCustomerInfo')) return _json(infoBody(organizations: defaultOrgs));
      if (url.contains('/api_keys')) return _json({'msg': 'server error'}, 500);
      return _json({}, 404);
    });
    final result = await BigModelKeyService(client: mock).resolveBigModelCodingPlanApiKey('at-1');
    expect(result, isNull);
  });

  test('copy 失败拿不到 secretKey → null', () async {
    final mock = MockClient((req) async {
      final url = req.url.toString();
      if (url.endsWith('/getCustomerInfo')) return _json(infoBody(organizations: defaultOrgs));
      if (url.contains('/copy/')) return _json({'msg': 'denied'}, 403);
      if (url.contains('/api_keys')) {
        return _json({'data': [
          {'name': 'zcode-api-key', 'apiKey': 'ak-1'}
        ]});
      }
      return _json({}, 404);
    });
    final result = await BigModelKeyService(client: mock).resolveBigModelCodingPlanApiKey('at-1');
    expect(result, isNull);
  });

  test('请求超时 → null（登录流程不挂起）', () async {
    final never = MockClient((req) => Completer<http.Response>().future);
    final result = await BigModelKeyService(
      client: never,
      timeout: const Duration(milliseconds: 50),
    ).resolveBigModelCodingPlanApiKey('at-1');
    expect(result, isNull);
  });
}
