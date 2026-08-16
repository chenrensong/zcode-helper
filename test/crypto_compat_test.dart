import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_helper/core/crypto.dart';

/// 与 Node 版 zcodeCrypto.js 交叉验证：Node 加密 → Dart 解密。
void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    final raw = jsonDecode(
      File('test/fixtures/crypto_fixture.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    fixture = raw;
  });

  test('Dart 可解密 Node 端 enc:v1 密文（含空、Unicode、长文本）', () async {
    final cases = (fixture['cases'] as Map).cast<String, dynamic>();
    final secret = fixture['secret'] as String;
    for (final entry in cases.entries) {
      final plain = (entry.value as Map)['plain'] as String;
      final ciphertext = (entry.value as Map)['ciphertext'] as String;
      final decrypted = await decrypt(ciphertext, secret: secret);
      expect(decrypted, plain, reason: 'case: ${entry.key}');
    }
  });

  test('Dart 自身加密/解密往返', () async {
    const secret = 'zcash-test-secret-2026';
    const text = 'Dart 侧往返：{"a":1,"b":"中文"}';
    final ct = await encrypt(text, secret: secret);
    expect(isEncrypted(ct), isTrue);
    expect(ct.startsWith(encPrefix), isTrue);
    final back = await decrypt(ct, secret: secret);
    expect(back, text);
  });

  test('错误密钥解密抛 FormatException', () async {
    final ct = await encrypt('secret payload', secret: 'key-a');
    await expectLater(
      decrypt(ct, secret: 'key-b'),
      throwsA(isA<FormatException>()),
    );
  });

  test('非密文原样返回', () async {
    expect(await decrypt('plain-text', secret: 'x'), 'plain-text');
    expect(await safeDecrypt(null), isNull);
    expect(await safeDecrypt('plain-text'), 'plain-text');
  });

  test('decryptJson 解析 Node 加密的 JSON 结构', () async {
    final ciphertext = ((fixture['cases'] as Map)['json'] as Map)['ciphertext'] as String;
    final decoded = await decryptJson(ciphertext, secret: fixture['secret'] as String);
    expect(decoded, isA<Map>());
    expect((decoded as Map)['email'], 'user@example.com');
    expect(decoded['activeProvider'], 'zai');
  });

  test('simpleHash 稳定输出', () {
    expect(simpleHash('zai'), simpleHash('zai'));
    expect(simpleHash('a'), isNot(simpleHash('b')));
    expect(simpleHash('').length, greaterThanOrEqualTo(1));
  });
}
