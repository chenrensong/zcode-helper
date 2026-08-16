import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/core/crypto.dart';
import 'package:zcode_helper/core/fingerprint.dart';
import 'package:zcode_helper/services/account_health.dart';
import 'package:zcode_helper/services/tokens.dart';

const _secret = 'fp-test-secret';

Future<void> _writeEncrypted(File file, Map<String, dynamic> data) async {
  final out = <String, dynamic>{};
  for (final entry in data.entries) {
    if (entry.value is String) {
      out[entry.key] = await encrypt(entry.value as String, secret: _secret);
    } else {
      out[entry.key] = entry.value;
    }
  }
  file.writeAsStringSync(jsonEncode(out));
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  late Directory root;
  late File credentialsFile;
  late File configFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('zcas-fp-');
    final v2 = Directory('${root.path}/v2')..createSync(recursive: true);
    credentialsFile = File('${v2.path}/credentials.json');
    configFile = File('${v2.path}/config.json');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('extractFingerprint 从 config.jwt + user_info 解析账号', () async {
    const uid = 'u_1234567890abcdef';
    const email = 'user@example.com';
    const jwtPayload = {'user_id': uid, 'customer_id': 'cust_1', 'user_key': 'key_1'};
    final jwt = 'eyJhbGciOiJIUzI1NiJ9.${_b64url(utf8.encode(jsonEncode(jwtPayload)))}.sig';
    final atJwt = 'eyJhdCI6MS.${_b64url(utf8.encode(jsonEncode({'customer_id': 'cust_1', 'user_key': 'key_1'})))}.sig';

    await _writeEncrypted(credentialsFile, {
      'oauth:active_provider': 'zai',
      'oauth:zai:user_info': jsonEncode({'email': email, 'name': 'Alice', 'avatar': 'https://a/x.png'}),
      'oauth:zai:access_token': atJwt,
      'zcodejwttoken': 'zw-$uid-abcdefghijk',
    });
    configFile.writeAsStringSync(jsonEncode({
      'provider': {
        'builtin:zai': {
          'enabled': true,
          'options': {'apiKey': jwt},
        },
        'builtin:bigmodel': {
          'enabled': false,
          'options': {'apiKey': ''},
        },
      },
    }));

    final fp = await extractFingerprint(
      credentialsFile: credentialsFile.path,
      configFile: configFile.path,
      secret: _secret,
    );

    expect(fp, isNotNull);
    expect(fp!.userId, uid);
    expect(fp.provider, 'builtin:zai');
    expect(fp.email, email);
    expect(fp.label, email);
    expect(fp.shortId, uid.substring(0, 8));
    expect(fp.emailShortId, startsWith('em-'));
    expect(fp.customerId, 'cust_1');
  });

  // 回归：zai 槽位 JWT 的 user_id 是数字（Electron 同款数据形态），
  // 若按 String 严格断言会跳过 zai 槽、误中残留的 bigmodel-start-plan
  // 平台 JWT，把 Z.ai 账号标成 bigmodel。
  test('zai 槽位 user_id 为数字时仍选中 zai 槽（不被残留 bigmodel 槽误导）', () async {
    const email = '13800001111@phone.local';
    final zaiJwt = 'eyJhbGciOiJIUzI1NiJ9.'
        '${_b64url(utf8.encode(jsonEncode({'user_id': 1234567})))}.sig';
    final leftoverBmJwt = 'eyJhbGciOiJIUzI1NiJ9.'
        '${_b64url(utf8.encode(jsonEncode({'user_id': '7654321098765432'})))}.sig';

    await _writeEncrypted(credentialsFile, {
      'oauth:active_provider': 'zai',
      'oauth:zai:user_info': jsonEncode({'email': email, 'name': '测试用户0000'}),
      'zcodejwttoken': 'zw-platform',
    });
    configFile.writeAsStringSync(jsonEncode({
      'provider': {
        'builtin:zai': {
          'enabled': true,
          'options': {'apiKey': zaiJwt},
        },
        'builtin:bigmodel-start-plan': {
          'enabled': false,
          'options': {'apiKey': leftoverBmJwt},
        },
      },
    }));

    final fp = await extractFingerprint(
      credentialsFile: credentialsFile.path,
      configFile: configFile.path,
      secret: _secret,
    );

    expect(fp, isNotNull);
    expect(fp!.provider, startsWith('builtin:zai'));
    expect(fp.provider, isNot(contains('bigmodel')));
    expect(fp.userId, '1234567');
    expect(fp.shortId, '1234567');
    expect(fp.label, email);
  });

  test('token 候选提取顺序：zcodejwttoken 优先', () async {
    await _writeEncrypted(credentialsFile, {
      'oauth:active_provider': 'zai',
      'zcodejwttoken': 'zw-first-token-abcdefghijklmnop',
      'oauth:zai:access_token': 'at-second-token-abcdefghijklmn',
    });
    configFile.writeAsStringSync(jsonEncode({
      'provider': {
        'builtin:zai': {
          'enabled': true,
          'options': {'apiKey': 'cfg-third-token-abcdefghijk'},
        },
      },
    }));

    final tokens = await readCandidateTokensFromFiles(
      credentialsFile.path,
      configFile.path,
      secret: _secret,
    );
    expect(tokens, hasLength(3));
    expect(tokens.first, startsWith('zw-first'));
    expect(tokens[1], startsWith('at-second'));
    expect(tokens[2], startsWith('cfg-third'));
  });

  test('validateSnapshot：完整快照为 healthy', () async {
    const jwtPayload = {'user_id': 'user-123', 'sub': 'user-123'};
    final jwt = 'eyJhbGciOiJIUzI1NiJ9.${_b64url(utf8.encode(jsonEncode(jwtPayload)))}.sig';
    await _writeEncrypted(credentialsFile, {
      'oauth:active_provider': 'zai',
      'zcodejwttoken': 'zw-healthy-token-abcdefghijklmn',
      'oauth:zai:user_info': jsonEncode({'email': 'a@b.c', 'name': 'A'}),
    });
    configFile.writeAsStringSync(jsonEncode({
      'provider': {
        'builtin:zai': {'enabled': true, 'options': {'apiKey': jwt}},
      },
    }));
    final health = await validateSnapshot(
      Snapshot(credentials: credentialsFile.readAsStringSync(), config: configFile.readAsStringSync()),
      secret: _secret,
    );
    expect(health.status, 'healthy');
    expect(health.details['hasTokens'], isTrue);
    expect(health.details['canDecryptUserInfo'], isTrue);
  });

  test('validateSnapshot：缺失 config 为 error', () async {
    await _writeEncrypted(credentialsFile, {
      'oauth:active_provider': 'zai',
      'zcodejwttoken': 'zw-err-token-abcdefghijklmnopq',
    });
    final health = await validateSnapshot(
      Snapshot(
        credentials: credentialsFile.readAsStringSync(),
        config: '',
      ),
      secret: _secret,
    );
    expect(health.status, 'error');
    expect(health.errors, isNotEmpty);
  });

  test('validateSnapshot：BigModel 无 JWT apiKey，指纹走兜底仍为 healthy', () async {
    await _writeEncrypted(credentialsFile, {
      'oauth:active_provider': 'bigmodel',
      'oauth:bigmodel:user_info': jsonEncode({'id': 'bm-user-001', 'username': 'BM'}),
      'oauth:bigmodel:access_token': 'opaque-bigmodel-access-token-value',
      'zcodejwttoken': 'zw-bigmodel-opaque-token-12345678',
    });
    configFile.writeAsStringSync(jsonEncode({
      'provider': {
        'builtin:bigmodel': {'enabled': true, 'options': {'apiKey': ''}},
        'builtin:bigmodel-coding-plan': {
          'enabled': true,
          'options': {'apiKey': 'kid-12345.secret-6789012345678901234567890'},
        },
      },
    }));
    final health = await validateSnapshot(
      Snapshot(credentials: credentialsFile.readAsStringSync(), config: configFile.readAsStringSync()),
      secret: _secret,
    );
    expect(health.status, 'healthy');
    expect(health.details['userId'], 'bm-user-001');
  });
}
