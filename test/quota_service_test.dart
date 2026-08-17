import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/services/quota_service.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// BigModel / Z.ai quota/limit 同格式响应。
Map<String, dynamic> _limitBody({required String level}) => {
      'code': 200,
      'data': {
        'level': level,
        'limits': [
          {
            'type': 'TOKENS_LIMIT',
            'percentage': 42.5,
            'unit': 3,
            'number': 5,
            'nextResetTime': 1786800000000,
          },
          {
            'type': 'TOKENS_LIMIT',
            'percentage': 61.0,
            'unit': 6,
            'number': 1,
            'nextResetTime': 1787400000000,
          },
          {
            'type': 'TIME_LIMIT',
            'percentage': 3.0,
            'currentValue': 3,
            'usage': 100,
            'unit': 5,
            'number': 1,
          },
        ],
      },
    };

Snapshot _snapshot(Map<String, dynamic> credentials) => Snapshot(
      credentials: jsonEncode(credentials),
      config: jsonEncode({'provider': {}}),
    );

void main() {
  test('BigModel 快照：quota/limit limits 归一化为 5小时/每周/MCP 三项', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'open.bigmodel.cn');
      expect(request.url.path, '/api/monitor/usage/quota/limit');
      expect(request.headers['authorization'], 'bm-access-token-abcdefghijklmnop');
      return _json(_limitBody(level: 'lite'));
    });
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'bigmodel',
      'oauth:bigmodel:access_token': 'bm-access-token-abcdefghijklmnop',
    }));

    expect(overview.isOk, isTrue);
    expect(overview.provider, 'bigmodel');
    expect(overview.plan?.label, 'Lite');
    expect(overview.items, hasLength(3));
    expect(overview.items[0].label, contains('5小时'));
    expect(overview.items[0].used, 42.5);
    expect(overview.items[0].quota, 100);
    expect(overview.items[0].resetAt, 1786800000000);
    expect(overview.items[1].label, contains('周'));
    expect(overview.items[1].resetAt, 1787400000000);
    expect(overview.items[2].label, startsWith('MCP'));
  });

  test('Z.ai 快照：优先 api.z.ai quota/limit，access_token 不加 Bearer', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'api.z.ai') {
        expect(request.headers['authorization'], 'zai-access-token-abcdefghijklmnop');
        return _json(_limitBody(level: 'pro'));
      }
      throw StateError('不应走 billing 兜底: ${request.url}');
    });
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'zai',
      'oauth:zai:access_token': 'zai-access-token-abcdefghijklmnop',
      'zcodejwttoken': 'zcode-jwt-token-abcdefghijklmnopqrs',
    }));

    expect(overview.isOk, isTrue);
    expect(overview.provider, 'zai');
    expect(overview.plan?.label, 'Pro');
  });

  test('Z.ai 兜底：quota/limit 401 → billing current+balance（带 app_version/platform）', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'api.z.ai') {
        return _json({'msg': 'unauthorized'}, 401);
      }
      expect(request.url.host, 'zcode.z.ai');
      expect(request.url.queryParameters['app_version'], '4.1.10');
      expect(request.url.queryParameters['platform'], 'win32-x64');
      expect(request.headers['authorization'], 'Bearer zcode-jwt-token-abcdefghijklmnopqrs');
      if (request.url.path.contains('billing/current')) {
        return _json({
          'data': {
            'plans': [
              {'status': 'active', 'plan_id': 'zcode-max-monthly', 'name': 'Max'},
            ],
          },
        });
      }
      return _json({
        'data': {
          'balances': [
            {
              'show_name': 'GLM Coding',
              'total_units': 120,
              'used_units': 30,
              'remaining_units': 90,
            },
          ],
        },
      });
    });
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'zai',
      'zcodejwttoken': 'zcode-jwt-token-abcdefghijklmnopqrs',
    }));

    expect(overview.isOk, isTrue);
    expect(overview.plan?.label, 'Max');
    expect(overview.items, isNotEmpty);
    expect(overview.items.first.label, 'GLM Coding 剩余');
    expect(overview.items.first.used, 30);
    expect(overview.items.first.quota, 120);
  });

  test('quota/limit 返回 code:500 不存在 plan → 无 Coding Plan', () async {
    final client = MockClient((request) async {
      return _json({'code': 500, 'msg': '当前用户不存在coding plan'});
    });
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'bigmodel',
      'oauth:bigmodel:access_token': 'bm-access-token-abcdefghijklmnop',
    }));

    expect(overview.status, 'noop');
    expect(overview.error, contains('Coding Plan'));
  });

  test('BigModel 200 空 body：短退避重试后成功', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls <= 2) return http.Response('', 200);
      return _json(_limitBody(level: 'max'));
    });
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'bigmodel',
      'oauth:bigmodel:access_token': 'bm-access-token-abcdefghijklmnop',
    }));

    expect(calls, 3);
    expect(overview.isOk, isTrue);
    expect(overview.plan?.label, 'Max');
  });

  test('BigModel 200 持续空 body → 友好错误而非 FormatException', () async {
    final client = MockClient((request) async => http.Response('', 200));
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'bigmodel',
      'oauth:bigmodel:access_token': 'bm-access-token-abcdefghijklmnop',
    }));

    expect(overview.status, 'error');
    expect(overview.error, contains('空响应'));
    expect(overview.error, isNot(contains('FormatException')));
  });

  test('BigModel 200 返回 HTML → 响应格式异常', () async {
    final client = MockClient((request) async => http.Response('<html>502 Bad Gateway</html>', 200));
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'bigmodel',
      'oauth:bigmodel:access_token': 'bm-access-token-abcdefghijklmnop',
    }));

    expect(overview.status, 'error');
    expect(overview.error, contains('响应格式异常'));
  });

  test('billing 405 → 无 Coding Plan；全部 401 → 明确过期提示', () async {
    final unsupported = MockClient((request) async => _json({'message': 'no'}, 405));
    final overview = await QuotaService(client: unsupported, secret: 'test')
        .overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'zai',
      'zcodejwttoken': 'zcode-jwt-token-abcdefghijklmnopqrs',
    }));
    expect(overview.status, 'noop');

    final expired = MockClient((request) async => _json({'message': 'expired'}, 401));
    final overview2 = await QuotaService(client: expired, secret: 'test')
        .overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'zai',
      'zcodejwttoken': 'zcode-jwt-token-abcdefghijklmnopqrs',
    }));
    expect(overview2.status, 'error');
    expect(overview2.error, contains('过期'));
  });

  test('无候选 token → error', () async {
    final client = MockClient((request) async => _json({}, 200));
    final service = QuotaService(client: client, secret: 'test');
    final overview = await service.overviewFromSnapshot(_snapshot({
      'oauth:active_provider': 'zai',
    }));
    expect(overview.status, 'error');
    expect(overview.error, isNotEmpty);
  });
}
