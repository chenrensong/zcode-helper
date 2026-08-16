import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/core/crypto.dart';
import 'package:zcode_helper/core/paths.dart';
import 'package:zcode_helper/services/account_store.dart';
import 'package:zcode_helper/services/login_controller.dart';
import 'package:zcode_helper/services/oauth_service.dart';
import 'package:zcode_helper/services/oauth_writer.dart';
import 'package:zcode_helper/services/switcher.dart';
import 'fakes/fake_zcode_platform.dart';

/// 模拟用户机器上已有 ZCode 登录态（bare 明文形式，模拟非 v2 衍生或已存在配置）。
void _writeCurrentDevLogin(AppPaths paths) {
  final v2 = Directory(paths.zcodeV2Dir)..createSync(recursive: true);
  File(p.join(v2.path, 'credentials.json')).writeAsStringSync(jsonEncode({
    'oauth:active_provider': 'zai',
    'oauth:zai:user_info': jsonEncode({'email': 'old@example.com', 'name': 'OldUser'}),
    'oauth:zai:access_token': 'old-access-token-xxxxxxxx',
    'zcodejwttoken': 'old-platform-token-xxxx',
  }));
  File(p.join(v2.path, 'config.json')).writeAsStringSync(jsonEncode({
    'providers': {
      'builtin:zai': 'enabled',
      'builtin:bigmodel': 'disabled',
    },
  }));
}

/// 生成按 provider 返回正确形状的 OAuth 端点 mock。
MockClient _oauthMock(String provider) {
  return MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/api/v1/oauth/token')) {
      if (provider == 'bigmodel') {
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {
              'token': 'zw-bm-plat',
              'bigmodel': {'access_token': 'bm-access-1', 'refresh_token': 'bm-refresh-1'},
              'user': {'customerNumber': '8000000000001', 'email': 'bm@zz.cn', 'name': '贝母'},
            },
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'token': 'zw-plat',
            'zai': {'access_token': 'at-abc', 'refresh_token': 'rt-x'},
            'user': {'email': 'new@z.ai', 'nickName': 'NewUser'},
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/z/login')) {
      return http.Response(jsonEncode({'code': 0, 'data': {'access_token': 'biz-jwt-1'}}), 200);
    }
    if (path.endsWith('/getCustomerInfo')) {
      // 无 organizations → coding-plan key 派生为 null，走“不出 key”分支。
      return http.Response(jsonEncode({'code': 200, 'data': {'email': 'bm@zz.cn'}}), 200);
    }
    return http.Response('{}', 404);
  });
}

void main() {
  late Directory tempHome;
  late Directory tempZcas;
  late AppPaths paths;
  late AccountStore store;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('zcas-login-home-');
    tempZcas = Directory.systemTemp.createTempSync('zcas-login-store-');
    paths = AppPaths(home: tempHome.path, zcasDataDir: tempZcas.path);
    store = AccountStore(paths);
  });

  tearDown(() {
    for (final d in [tempHome, tempZcas]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('zai 登录端到端：接管 zcode:// → 开浏览器 → 协议回调 → 换令牌 → 写盘 → 捕获 → 还原现场', () async {
    _writeCurrentDevLogin(paths);
    final prevCreds = File(paths.credentialsFile).readAsStringSync();
    final prevConfig = File(paths.configFile).readAsStringSync();

    final platform = FakeZCodePlatform();
    String? tokenBody;
    final oauth = OAuthService(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/api/v1/oauth/token')) {
          tokenBody = req.body;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'token': 'zw-plat',
                'zai': {'access_token': 'at-abc', 'refresh_token': 'rt-x'},
                'user': {'email': 'new@z.ai', 'nickName': 'NewUser'},
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (req.url.path.endsWith('/z/login')) {
          return http.Response(jsonEncode({'code': 0, 'data': {'access_token': 'biz-jwt-1'}}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final controller = LoginController(
      paths: paths,
      platform: platform,
      store: store,
      oauth: oauth,
    );

    final phases = <LoginPhase>[];
    final fut = controller.login(provider: 'zai', onPhase: (ph, _) => phases.add(ph));
    // 等待 OAuth 窗口打开后，从授权 URL 提取 state 模拟窗口拦截到的回调。
    String? state;
    for (var i = 0; i < 40 && state == null; i++) {
      final url = platform.lastOAuthWindowUrl;
      if (url != null) state = Uri.parse(url).queryParameters['state'];
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(state, isNotNull);
    platform.emitOAuthCallback('zcode://oauth/callback?code=cb-code-9&state=$state');
    final result = await fut;

    expect(result.provider, 'zai');
    expect(result.created, isTrue);
    expect(result.skipped, isFalse);
    expect(result.email, 'new@z.ai');
    expect(result.account, isNotNull);

    // 打开的是应用内 OAuth 窗口（Z.ai 授权页，redirect 为官方回调）
    expect(platform.lastOAuthWindowUrl, contains('chat.z.ai/auth'));
    expect(platform.lastOAuthWindowUrl!, contains('state='));
    expect(
      Uri.decodeFull(Uri.parse(platform.lastOAuthWindowUrl!).queryParameters['redirect_uri'] ?? ''),
      contains('redirect=zcode://oauth/callback'),
    );

    // 登录全程零打扰：不杀进程、不启动进程、不动协议
    expect(platform.terminated, isEmpty);
    expect(platform.launchCalled, isFalse);

    // token 请求体对齐 Electron oauthCli.js
    final body = jsonDecode(tokenBody!) as Map<String, dynamic>;
    expect(body['provider'], 'zai');
    expect(body['redirect_uri'], 'zcode://oauth/callback');
    expect(body['code'], 'cb-code-9');
    expect(body['state'], state);

    // 快照落库且标签为规范化 email
    final entries = await store.list();
    expect(entries, hasLength(1));
    expect(entries.first.meta.label, 'new@z.ai');

    // 现场还原：live 文件与登录前一致
    expect(File(paths.credentialsFile).readAsStringSync(), prevCreds);
    expect(File(paths.configFile).readAsStringSync(), prevConfig);

    // 阶段进度完整
    expect(
      phases,
      containsAll([LoginPhase.preparing, LoginPhase.browserOpen, LoginPhase.waiting, LoginPhase.exchanging, LoginPhase.saving, LoginPhase.done]),
    );
    controller.close();
  });

  test('bigmodel 登录端到端：bigmodel.cn 授权页 + native profile 捕获', () async {
    _writeCurrentDevLogin(paths);
    final platform = FakeZCodePlatform();
    final controller = LoginController(
      paths: paths,
      platform: platform,
      store: store,
      oauth: OAuthService(client: _oauthMock('bigmodel')),
    );

    final fut = controller.login(provider: 'bigmodel');
    controller.submitManualCode('bm-code-88');
    final result = await fut;
    expect(result.provider, 'bigmodel');
    expect(result.email, 'bm@zz.cn');
    expect(result.created, isTrue);

    expect(platform.lastOAuthWindowUrl, contains('bigmodel.cn/login'));
    expect(platform.lastOAuthWindowUrl!, contains('appId=zcode'));

    // 捕获的快照账号：bigmodel 原生 user_info 以 displayName 为标签
    final entries = await store.list();
    expect(entries, hasLength(1));
    expect(entries.first.meta.label, isNotEmpty);
    expect(entries.first.meta.label, contains('贝母'));
    controller.close();
  });

  test('登录写盘产物：凭据加密、provider 语义、setting family（bigmodel）', () async {
    final writer = OAuthWriter(paths);
    await writer.writeCredentials(
      tokenSet: OAuthTokenSet(
        token: 'zw-bm-plat',
        zaiAccessToken: 'bm-access-1',
        refreshToken: 'bm-refresh-1',
        user: {'customerNumber': '1', 'email': 'x@x.cn'},
      ),
      userInfo: toNativeBigModelUserProfile({'customerNumber': '1', 'email': 'x@x.cn'}),
      provider: 'bigmodel',
    );

    final creds = jsonDecode(File(paths.credentialsFile).readAsStringSync()) as Map<String, dynamic>;
    expect(creds['oauth:active_provider'], startsWith('enc:v1:'));
    expect(creds['zcodejwttoken'], startsWith('enc:v1:'));
    expect(creds['oauth:bigmodel:access_token'], startsWith('enc:v1:'));
    expect(creds.containsKey('oauth:zai:access_token'), isFalse);
    expect(await decrypt(creds['oauth:active_provider'] as String), 'bigmodel');
    expect(await decrypt(creds['oauth:bigmodel:access_token'] as String), 'bm-access-1');
    expect(await decrypt(creds['zcodejwttoken'] as String), 'zw-bm-plat');
    // BigModel user_info 是原生 cached-profile 契约（无 email 字段）
    final ui = jsonDecode(await decrypt(creds['oauth:bigmodel:user_info'] as String)) as Map<String, dynamic>;
    expect(ui['id'], '1');
    expect(ui['username'], isNotEmpty);
    final raw = ui['rawProfile'] as Map<String, dynamic>;
    expect(raw['zcodeProfileSchemaVersion'], 2);

    // config：bigmodel enabled；对向 zai 不存在或为 disabled（与 Electron updateConfigProviders 一致）
    final config = jsonDecode(File(paths.configFile).readAsStringSync()) as Map<String, dynamic>;
    final providers = config['provider'] as Map<String, dynamic>;
    final zaiEntry = providers['builtin:zai'];
    if (zaiEntry is Map) {
      expect(zaiEntry['enabled'], isFalse);
    }
    expect((providers['builtin:bigmodel'] as Map)['enabled'], isTrue);

    // setting：providerFamilyDomain=bigmodel（与真实 setting.json 一致，无域名后缀）
    final setting = jsonDecode(File(paths.settingFile).readAsStringSync()) as Map<String, dynamic>;
    expect(setting['providerFamilyDomain'], 'bigmodel');
  });

  test('登录不杀进程：运行中的主客户端与实例客户端全程不受影响', () async {
    _writeCurrentDevLogin(paths);
    final platform = FakeZCodePlatform();
    platform.running = const [
      RuntimeProcess(pid: 555, name: 'ZCode'),
      RuntimeProcess(pid: 556, name: 'ZCode [z.ai]'),
    ];
    final controller = LoginController(
      paths: paths,
      platform: platform,
      store: store,
      oauth: OAuthService(client: _oauthMock('zai')),
    );

    final fut = controller.login(provider: 'zai');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    controller.submitManualCode('manual-code-123');
    await fut;

    expect(platform.terminated, isEmpty);
    expect(platform.launchCalled, isFalse);
    expect(platform.running, hasLength(2));
    controller.close();
  });

  test('用户关闭 OAuth 窗口 → 登录取消', () async {
    final platform = FakeZCodePlatform();
    final controller = LoginController(
      paths: paths,
      platform: platform,
      store: store,
      oauth: OAuthService(client: _oauthMock('zai')),
    );

    final fut = controller.login(provider: 'zai');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    platform.emitOAuthWindowClosed();
    await expectLater(fut, throwsA(isA<SwitchAborted>()));
    controller.close();
  });

  test('state 不匹配的 zcode:// 回调被忽略，手动授权码兜底可用', () async {
    _writeCurrentDevLogin(paths);
    final platform = FakeZCodePlatform();
    final controller = LoginController(
      paths: paths,
      platform: platform,
      store: store,
      oauth: OAuthService(client: _oauthMock('zai')),
    );

    final fut = controller.login(provider: 'zai');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // 伪造他人会话的回调与无 state 的回调：均不应换 token
    platform.emitOAuthCallback('zcode://oauth/callback?code=stolen&state=deadbeef');
    platform.emitOAuthCallback('zcode://oauth/callback?code=no-state');
    controller.submitManualCode('manual-code-123');
    final result = await fut;
    expect(result.created, isTrue);
    expect(result.email, 'new@z.ai');

    final entries = await store.list();
    expect(entries, hasLength(1));
    controller.close();
  });

  test('取消（isCancelled）→ SwitchAborted', () async {
    final platform = FakeZCodePlatform();
    final controller = LoginController(
      paths: paths,
      platform: platform,
      store: store,
      oauth: OAuthService(client: MockClient((req) async => http.Response('{}', 500))),
    );
    var cancelled = false;
    final fut = controller.login(provider: 'zai', isCancelled: () => cancelled);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    cancelled = true;
    await expectLater(fut, throwsA(isA<SwitchAborted>()));
  });

  test('normalizeUserInfo / toNativeBigModelUserProfile 规整字段', () {
    final zai = normalizeUserInfo({'email': 'a@b.c', 'nickName': 'BB', 'avatar': 'http://x', 'unknown': 1});
    expect(zai, {'email': 'a@b.c', 'name': 'BB', 'avatar': 'http://x', 'user_id': ''});
    expect(zai.containsKey('unknown'), isFalse);

    final bm = toNativeBigModelUserProfile({'customerNumber': '9', 'email': 'm@n.cn', 'phone': '138'});
    expect(bm['id'], '9');
    expect(bm['username'], 'm@n.cn');
    expect(bm['displayName'], 'm@n.cn');
    final raw = bm['rawProfile'] as Map<String, dynamic>;
    expect(raw['zcodeProfileSchemaVersion'], 2);
  });
}
