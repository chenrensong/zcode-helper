import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/core/crypto.dart';
import 'package:zcode_helper/core/paths.dart';
import 'package:zcode_helper/services/fs_utils.dart';
import 'package:zcode_helper/services/switcher.dart';
import 'fakes/fake_zcode_platform.dart';

const _secret = 'switch-test-secret';

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Future<String> _enc(String plain) => encrypt(plain, secret: _secret);

Future<Map<String, dynamic>> _zaiSnapshot() async {
  const jwtPayload = {'user_id': 'u_switch_target_001'};
  final jwt = 'eyJhbGciOiJIUzI1NiJ9.${_b64url(utf8.encode(jsonEncode(jwtPayload)))}.sig';
  return {
    'credentials': jsonEncode({
      'oauth:active_provider': 'zai',
      'oauth:zai:user_info': await _enc(jsonEncode({'email': 'target@example.com', 'name': 'Target'})),
      'oauth:zai:access_token': await _enc('at-target-token-abcdefghijk'),
      'zcodejwttoken': 'zw-target-token-abcdefghijkl',
    }),
    'config': jsonEncode({
      'provider': {
        'builtin:zai': {
          'enabled': false,
          'options': {'apiKey': jwt},
        },
        'builtin:bigmodel': {
          'enabled': false,
          'options': {'apiKey': ''},
        },
      },
    }),
  };
}

void main() {
  late Directory tempHome;
  late Directory tempZcas;
  late AppPaths paths;
  late FakeZCodePlatform fake;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('zcas-sw-home-');
    tempZcas = Directory.systemTemp.createTempSync('zcas-sw-');
    paths = AppPaths(home: tempHome.path, zcasDataDir: tempZcas.path);
    fake = FakeZCodePlatform();
  });

  tearDown(() {
    for (final d in [tempHome, tempZcas]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  SwitchController controller({int pollMs = 10}) => SwitchController(
        paths: paths,
        platform: fake,
        secret: _secret,
        pollMs: pollMs,
      );

  void writeCurrent(Map<String, dynamic> credsMap, Map<String, dynamic> cfgMap) {
    Directory(paths.zcodeV2Dir).createSync(recursive: true);
    File(paths.credentialsFile).writeAsStringSync(jsonEncode(credsMap));
    File(paths.configFile).writeAsStringSync(jsonEncode(cfgMap));
  }

  test('冷启动切换：备份 + 写入 + 清缓存 + 启动', () async {
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    final snapMap = await _zaiSnapshot();
    final snapshot = Snapshot(credentials: snapMap['credentials'] as String, config: snapMap['config'] as String);

    final result = await controller().switchTo(rawSnapshot: snapshot, snapshotId: 'em-test');
    expect(result.mode, 'cold-start');
    expect(result.wasRunning, isFalse);
    expect(result.restarted, isTrue);
    expect(fake.launchCalled, isTrue);

    // 写入成功
    expect(jsonDecode(File(paths.credentialsFile).readAsStringSync())['oauth:active_provider'], 'zai');
    // 备份存在且等于切换前内容
    final backup = jsonDecode(File('${paths.backupDir}/credentials.json').readAsStringSync());
    expect(backup['oauth:active_provider'], 'zai');
  });

  test('备份与回滚包含 setting.json：provider family 不残留错配', () async {
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    File(paths.settingFile)
        .writeAsStringSync(jsonEncode({'providerFamilyDomain': 'z.ai'}));
    // 切到 BigModel（setting.json 的 family 域会被改写为 bigmodel）
    final bmCreds = jsonEncode({
      'oauth:active_provider': await _enc('bigmodel'),
      'oauth:bigmodel:user_info': await _enc(jsonEncode({
        'email': 'bm@example.com',
        'name': 'BM User',
        'user_id': 'bm-rollback-001',
      })),
      'zcodejwttoken': await _enc('zw-bm-rollback-token-abcdefgh'),
    });
    final bmCfg = jsonEncode({
      'provider': {
        'builtin:bigmodel': {'enabled': false, 'options': {'apiKey': ''}},
      },
    });
    await controller().switchTo(rawSnapshot: Snapshot(credentials: bmCreds, config: bmCfg));
    expect(
      jsonDecode(File(paths.settingFile).readAsStringSync())['providerFamilyDomain'],
      'bigmodel',
    );
    // 备份里有 setting.json
    expect(File('${paths.backupDir}/setting.json').existsSync(), isTrue);

    // 回滚后 setting.json 一并还原，不留下凭据/域错配
    controller().rollbackToLast();
    expect(
      jsonDecode(File(paths.settingFile).readAsStringSync())['providerFamilyDomain'],
      'z.ai',
    );
  });

  test('运行中：自动结束进程并重启', () async {
    fake.running = [const RuntimeProcess(pid: 4242, name: 'ZCode')];
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    final snapMap = await _zaiSnapshot();

    final result = await controller(pollMs: 5).switchTo(
      rawSnapshot: Snapshot(credentials: snapMap['credentials'] as String, config: snapMap['config'] as String),
    );
    expect(result.mode, 'auto-restart');
    expect(result.wasRunning, isTrue);
    expect(fake.terminated, contains(4242));
    expect(fake.launchCalled, isTrue);
  });

  test('实例客户端 ZCode [xxx] 使用隔离 HOME，切换时不杀（对齐 Electron）', () async {
    fake.running = const [
      RuntimeProcess(pid: 100, name: 'ZCode'),
      RuntimeProcess(pid: 200, name: 'ZCode [z.ai]'),
    ];
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    final snapMap = await _zaiSnapshot();

    final result = await controller(pollMs: 5).switchTo(
      rawSnapshot: Snapshot(credentials: snapMap['credentials'] as String, config: snapMap['config'] as String),
    );
    expect(result.wasRunning, isTrue);
    expect(fake.terminated, contains(100));
    expect(fake.terminated, isNot(contains(200)));
  });

  test('主客户端杀不掉（超时）→ 中止切换，不启动新客户端（防双开）', () async {
    final stuck = _StuckZCodePlatform();
    stuck.running = const [RuntimeProcess(pid: 4242, name: 'ZCode')];
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    final snapMap = await _zaiSnapshot();
    final c = SwitchController(paths: paths, platform: stuck, secret: _secret, pollMs: 5, autoWaitMs: 60);

    await expectLater(
      c.switchTo(rawSnapshot: Snapshot(credentials: snapMap['credentials'] as String, config: snapMap['config'] as String)),
      throwsA(isA<SwitchError>()),
    );
    expect(stuck.launchCalled, isFalse);
    // 未切换成功：磁盘登录态保持原样
    expect(jsonDecode(File(paths.credentialsFile).readAsStringSync())['oauth:active_provider'], 'zai');
  });

  test('BigModel 快照：user_info 标准化为 v2 原生结构并加密写回', () async {
    writeCurrent({'oauth:active_provider': 'bigmodel'}, {'provider': {}});
    final creds = jsonEncode({
      'oauth:active_provider': await _enc('bigmodel'),
      'oauth:bigmodel:user_info': await _enc(jsonEncode({
        'email': 'bm@example.com',
        'name': 'BM User',
        'user_id': 'legacy-bm-001',
        'avatar': 'https://a/av.png',
      })),
      'oauth:bigmodel:access_token': await _enc('at-bigmodel-token-abcdefghijk'),
      'zcodejwttoken': await _enc('zw-bm-token-abcdefghijkl'),
    });
    final cfg = jsonEncode({
      'provider': {
        'builtin:bigmodel': {'enabled': false, 'options': {'apiKey': ''}},
        'builtin:bigmodel-coding-plan': {
          'enabled': false,
          'options': {'apiKey': 'eyJold-api-key-value-000000'},
        },
      },
    });
    final c = SwitchController(
      paths: paths,
      platform: fake,
      secret: _secret,
      deriveCodingPlanKey: (at) async => 'new-key.secret',
    );
    await c.switchTo(rawSnapshot: Snapshot(credentials: creds, config: cfg));

    // user_info 已标准化
    final afterCreds = jsonDecode(File(paths.credentialsFile).readAsStringSync()) as Map<String, dynamic>;
    final userInfo = jsonDecode(await decrypt(afterCreds['oauth:bigmodel:user_info'] as String, secret: _secret)) as Map;
    expect(userInfo['id'], 'legacy-bm-001');
    expect(userInfo['username'], 'BM User');
    expect(userInfo['displayName'], 'BM User');
    expect((userInfo['rawProfile'] as Map)['zcodeProfileSchemaVersion'], 2);

    // coding-plan key 已派生替换
    final afterCfg = jsonDecode(File(paths.configFile).readAsStringSync()) as Map<String, dynamic>;
    final planSlot = ((afterCfg['provider'] as Map)['builtin:bigmodel-coding-plan'] as Map);
    expect(((planSlot['options'] as Map)['apiKey']), 'new-key.secret');
  });

  test('旧 apiKey 的 config 会被 updateConfigProviders 修复；非目标 provider 禁用', () async {
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    final snapMap = await _zaiSnapshotWithOldKey();
    await controller().switchTo(
      rawSnapshot: Snapshot(credentials: snapMap['credentials'] as String, config: snapMap['config'] as String),
    );
    final afterCfg = jsonDecode(File(paths.configFile).readAsStringSync()) as Map<String, dynamic>;
    final providers = afterCfg['provider'] as Map;
    expect((providers['builtin:zai'] as Map)['enabled'], isTrue);
    expect((providers['builtin:bigmodel'] as Map)['enabled'], isFalse);
    expect(((providers['builtin:zai'] as Map)['options'] as Map)['apiKey'], isNotNull);
  });

  test('setting.json 的 providerFamilyDomain 跟随目标账号 provider（不硬编码 zai）', () async {
    writeCurrent({'oauth:active_provider': 'zai'}, {'provider': {}});
    // 预置 setting.json（模拟真实环境已有该文件）
    Directory(paths.zcodeV2Dir).createSync(recursive: true);
    File(paths.settingFile).writeAsStringSync(jsonEncode({
      'providerFamilyDomain': 'zai',
      'modelProviderFamilyModes': {'zai': 'oauth'},
    }));

    final creds = jsonEncode({
      'oauth:active_provider': await _enc('bigmodel'),
      'oauth:bigmodel:user_info': await _enc(jsonEncode({
        'id': 'bm-001', 'username': 'BM', 'displayName': 'BM',
      })),
      'oauth:bigmodel:access_token': await _enc('at-bigmodel-abcdefghijk'),
      'zcodejwttoken': await _enc('zw-bm-token-abcdefghijkl'),
    });
    await controller().switchTo(rawSnapshot: Snapshot(
      credentials: creds,
      config: jsonEncode({'provider': {}}),
    ));

    final setting = jsonDecode(File(paths.settingFile).readAsStringSync()) as Map<String, dynamic>;
    expect(setting['providerFamilyDomain'], 'bigmodel');
    expect((setting['modelProviderFamilyModes'] as Map)['bigmodel'], 'oauth');
  });

  test('回滚：无备份抛错；有备份恢复', () {
    final c = controller();
    expect(() => c.rollbackToLast(), throwsA(isA<SwitchError>()));

    Directory(paths.backupDir).createSync(recursive: true);
    File('${paths.backupDir}/credentials.json').writeAsStringSync(jsonEncode({'k': 'old-creds'}));
    File('${paths.backupDir}/config.json').writeAsStringSync(jsonEncode({'k': 'old-config'}));
    c.rollbackToLast();
    expect(jsonDecode(File(paths.credentialsFile).readAsStringSync())['k'], 'old-creds');
    expect(jsonDecode(File(paths.configFile).readAsStringSync())['k'], 'old-config');
  });

  test('atomicWrite 写临时文件后 rename（无残留 .tmp）', () {
    final f = p.join(tempZcas.path, 'nested', 'file.json');
    atomicWrite(f, '{"a":1}');
    expect(File(f).existsSync(), isTrue);
    expect(File('$f.zcas.tmp').existsSync(), isFalse);
    expect(File(f).readAsStringSync(), '{"a":1}');
  });
}

/// terminatePids 假装成功但不真正移除进程：模拟优雅退出卡死。
class _StuckZCodePlatform extends FakeZCodePlatform {
  @override
  Future<Map<int, bool>> terminatePids(List<int> pids) async =>
      {for (final pid in pids) pid: true};
}

Future<Map<String, dynamic>> _zaiSnapshotWithOldKey() async {
  const jwtPayload = {'user_id': 'u_switch_old_key_99'};
  final jwt = 'eyJhbGciOiJIUzI1NiJ9.${_b64url(utf8.encode(jsonEncode(jwtPayload)))}.sig';
  return {
    'credentials': jsonEncode({
      'oauth:active_provider': 'zai',
      'oauth:zai:user_info': await _enc(jsonEncode({'email': 'oldkey@example.com'})),
      'oauth:zai:access_token': await _enc('at-oldkey-token-abcdefghijk'),
    }),
    'config': jsonEncode({
      'provider': {
        'builtin:zai': {'enabled': false, 'options': {'apiKey': jwt}},
        'builtin:zai-coding-plan': {
          'enabled': false,
          'options': {'apiKey': 'old-key-${Random().nextInt(1000)}'},
        },
        'builtin:bigmodel': {
          'enabled': false,
          'options': {'apiKey': ''},
        },
      },
    }),
  };
}
