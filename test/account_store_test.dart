import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zcode_helper/core/paths.dart';
import 'package:zcode_helper/services/account_store.dart';

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void _writeCurrentLogin(AppPaths paths) {
  const jwtPayload = {'user_id': 'u_store_test_123456', 'customer_id': 'cust_x'};
  final jwt = 'eyJhbGciOiJIUzI1NiJ9.${_b64url(utf8.encode(jsonEncode(jwtPayload)))}.sig';
  final v2 = Directory(paths.zcodeV2Dir)..createSync(recursive: true);
  File(p.join(v2.path, 'credentials.json')).writeAsStringSync(jsonEncode({
    'oauth:active_provider': 'zai',
    'oauth:zai:user_info': jsonEncode({'email': 'store@example.com', 'name': 'StoreUser'}),
    'oauth:zai:access_token': 'at-store-test-token-abcdefghijk',
    'zcodejwttoken': 'zw-store-token-abcdefghijkl',
  }));
  File(p.join(v2.path, 'config.json')).writeAsStringSync(jsonEncode({
    'provider': {
      'builtin:zai': {'enabled': true, 'options': {'apiKey': jwt}},
      'builtin:bigmodel': {'enabled': false, 'options': {'apiKey': ''}},
    },
  }));
}

void main() {
  late Directory tempHome;
  late Directory tempZcas;
  late AppPaths paths;
  late AccountStore store;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('zcas-home-');
    tempZcas = Directory.systemTemp.createTempSync('zcas-store-');
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

  test('捕获当前登录态 → 列表 → 加载 → 重命名 → 导出 → 删除', () async {
    _writeCurrentLogin(paths);

    final captured = await store.capture();
    expect(captured.created, isTrue);
    final id = captured.id;
    expect(id, startsWith('em-'));

    // 重复捕获跳过
    final again = await store.capture();
    expect(again.skipped, isTrue);

    // 列表
    final entries = await store.list();
    expect(entries, hasLength(1));
    expect(entries.first.meta.label, 'store@example.com');
    expect(entries.first.health, isNotNull);
    expect(entries.first.health!.isOk, isTrue);

    // 加载快照等于当前写入内容
    final snap = store.load(id);
    final creds = jsonDecode(snap.credentials) as Map<String, dynamic>;
    expect(creds['oauth:active_provider'], 'zai');

    // 重命名
    store.rename(id, '我的主账号', '备注内容');
    final entries2 = await store.list();
    expect(entries2.first.meta.label, '我的主账号');
    expect(entries2.first.meta.note, '备注内容');

    // 导出 → 删除 → 导入
    final payload = store.exportAccounts(null);
    expect((payload['accounts'] as List), hasLength(1));

    expect(store.remove(id), isTrue);
    expect(await store.list(), isEmpty);

    final imported = store.importAccounts(payload);
    expect(imported.count, 1);
    final entries3 = await store.list();
    expect(entries3, hasLength(1));
    expect(entries3.first.meta.note, '备注内容');

    // 重复导入（不覆盖）跳过
    final imported2 = store.importAccounts(payload);
    expect(imported2.count, 0);
    expect(imported2.skipped, hasLength(1));

    // 覆盖导入
    final imported3 = store.importAccounts(payload, overwrite: true);
    expect(imported3.count, 1);
  });

  test('rename 备注语义：null 保留旧备注，空串清除', () async {
    _writeCurrentLogin(paths);
    final captured = await store.capture(note: '原始备注');
    final id = captured.id;

    // note 传 null：只改 label，备注保留
    final r1 = store.rename(id, '新名字', null);
    expect(r1.note, '原始备注');
    // note 传空串：显式清除
    final r2 = store.rename(id, null, '');
    expect(r2.label, '新名字');
    expect(r2.note, isEmpty);
  });

  test('无登录态时捕获抛错', () async {
    await expectLater(
      store.capture(),
      throwsA(isA<StateError>()),
    );
  });

  test('非法 id 拒绝', () {
    expect(() => store.safeId('..//bad'), throwsArgumentError);
    expect(() => store.safeId('abc'), throwsArgumentError);
    expect(() => store.safeId('valid_id-123'), returnsNormally);
  });

  test('快照 id 与 meta 文件共处 storeDir', () async {
    _writeCurrentLogin(paths);
    await store.capture();
    final files = Directory(paths.storeDir).listSync().map((f) => p.basename(f.path)).toList();
    expect(files.where((f) => f.endsWith('.snap.json')), hasLength(1));
    expect(files.where((f) => f.endsWith('.meta.json')), hasLength(1));
  });
}
