import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/core/paths.dart';
import 'package:zcode_helper/services/account_store.dart';
import 'package:zcode_helper/services/instance_service.dart';
import 'fakes/fake_zcode_platform.dart';

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void _writeCurrentLogin(AppPaths paths) {
  const jwtPayload = {'user_id': 'u_inst_test_000001'};
  final jwt = 'eyJhbGciOiJIUzI1NiJ9.${_b64url(utf8.encode(jsonEncode(jwtPayload)))}.sig';
  final v2 = Directory(paths.zcodeV2Dir)..createSync(recursive: true);
  File(p.join(v2.path, 'credentials.json')).writeAsStringSync(jsonEncode({
    'oauth:active_provider': 'zai',
    'oauth:zai:user_info': jsonEncode({'email': 'inst@example.com', 'name': 'Inst'}),
    'zcodejwttoken': 'zw-inst-token-abcdefghijklm',
  }));
  File(p.join(v2.path, 'config.json')).writeAsStringSync(jsonEncode({
    'provider': {
      'builtin:zai': {'enabled': true, 'options': {'apiKey': jwt}},
    },
  }));
}

void main() {
  late Directory tempHome;
  late Directory tempZcas;
  late AppPaths paths;
  late AccountStore store;
  late FakeZCodePlatform fake;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('zcas-inst-home-');
    tempZcas = Directory.systemTemp.createTempSync('zcas-inst-');
    paths = AppPaths(home: tempHome.path, zcasDataDir: tempZcas.path);
    store = AccountStore(paths);
    fake = FakeZCodePlatform();
  });

  tearDown(() {
    for (final d in [tempHome, tempZcas]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  InstanceService service() => InstanceService(
        paths: paths,
        platform: fake,
        store: store,
      );

  test('mergeRuntimeInstances：受管运行识别 + 外部实例补齐', () {
    final managed = [
      const RuntimeInstance(id: 'inst-1', name: 'A', pid: 100, managed: true),
      const RuntimeInstance(id: 'inst-2', name: 'B', pid: null, managed: true),
    ];
    final running = [
      const RuntimeProcess(pid: 100, name: 'ZCode'),
      const RuntimeProcess(
          pid: 200,
          name: 'ZCode',
          bundleId: 'com.zcode.ZCode',
          path: '/Applications/ZCode.app/Contents/MacOS/ZCode'),
    ];
    final merged = InstanceService.mergeRuntimeInstances(managed, running);

    expect(merged, hasLength(3));
    final a = merged.firstWhere((i) => i.id == 'inst-1');
    expect(a.running, isTrue);
    final b = merged.firstWhere((i) => i.id == 'inst-2');
    expect(b.running, isFalse);
    final ext = merged.firstWhere((i) => i.id == 'external-200');
    expect(ext.managed, isFalse);
    expect(ext.running, isTrue);
    expect(ext.pid, 200);
    // 外部进程携带可执行路径，便于用户辨识来源
    expect(ext.exePath, '/Applications/ZCode.app/Contents/MacOS/ZCode');
  });

  test('mergeRuntimeInstances：按应用名认领多开实例（pid 变化后仍归属正确）', () {
    // spawn 记录的 pid 299 已被 Electron 重新拉起的应用进程 300 取代，
    // 应用名 "ZCode [ZCode #2]" 是认领依据。
    final managed = [
      const RuntimeInstance(id: 'inst-1', name: 'ZCode #2', pid: 299, managed: true),
    ];
    final running = [
      const RuntimeProcess(pid: 100, name: 'ZCode'),
      const RuntimeProcess(pid: 300, name: 'ZCode [ZCode #2]'),
    ];
    final merged = InstanceService.mergeRuntimeInstances(managed, running);

    expect(merged, hasLength(2));
    final inst = merged.firstWhere((i) => i.id == 'inst-1');
    expect(inst.running, isTrue);
    expect(inst.managed, isTrue);
    // 有效 pid 更新为名称认领到的应用进程
    expect(inst.pid, 300);
    // 300 不再作为外部实例出现
    expect(merged.where((i) => i.id == 'external-300'), isEmpty);
    // 主 ZCode 仍是外部
    expect(merged.where((i) => i.id == 'external-100'), isNotEmpty);
  });

  test('list：名称认领后把有效 pid 回写实例元数据', () async {
    await service().create(name: 'ZCode #9');
    fake.running = [
      const RuntimeProcess(pid: 777, name: 'ZCode [ZCode #9]'),
    ];
    final list = await service().list();
    final inst = list.firstWhere((i) => i.name == 'ZCode #9');
    expect(inst.running, isTrue);
    expect(inst.pid, 777);
    // 元数据 pid 已更新，stop 才能杀到真实进程
    final meta = service().read(inst.id);
    expect(meta!.pid, 777);
  });

  test('create：实例名重复直接拒绝（名称是进程认领键）', () async {
    await service().create(name: '工作号');
    expect(
      () => service().create(name: '工作号'),
      throwsA(isA<StateError>()),
    );
    // 大小写不敏感
    expect(
      () => service().create(name: ' 工作号 '),
      throwsA(isA<StateError>()),
    );
  });

  test('start：绑定的账号快照已删除 → 友好错误', () async {
    _writeCurrentLogin(paths);
    final captured = await store.capture();
    final inst = await service().create(name: '悬空', bindAccountId: captured.id);
    // 删除绑定账号后启动 → 可读错误，而不是内部 id 堆栈
    store.remove(captured.id);
    await expectLater(
      service().start(inst.id),
      throwsA(isA<StateError>().having(
        (e) => e.toString(),
        'message',
        contains('绑定的账号快照已删除'),
      )),
    );
  });

  test('mergeRuntimeInstances：无运行进程时无外部实例', () {
    final merged = InstanceService.mergeRuntimeInstances(
      [const RuntimeInstance(id: 'inst-1', name: 'A', managed: true)],
      const [],
    );
    expect(merged, hasLength(1));
    expect(merged.first.running, isFalse);
  });

  test('list：外部实例解析主目录账号（与 Electron 版行为一致）', () async {
    _writeCurrentLogin(paths);
    fake.running = [
      const RuntimeProcess(
        pid: 4242,
        name: 'ZCode',
        path: '/Applications/ZCode.app/Contents/MacOS/ZCode',
      ),
    ];

    final list = await service().list();
    final ext = list.firstWhere((i) => i.id == 'external-4242');
    expect(ext.managed, isFalse);
    expect(ext.exePath, '/Applications/ZCode.app/Contents/MacOS/ZCode');
    // 外部 ZCode 共享主目录登录态，应解析出当前登录账号
    expect(ext.account, isNotNull);
    expect(ext.account!.email, 'inst@example.com');
  });

  test('创建实例 → 写元数据 → 读取', () async {
    final inst = await service().create(name: 'ZCode #2');
    expect(inst.id, startsWith('inst-'));
    expect(inst.name, 'ZCode #2');
    expect(inst.managed, isTrue);

    final read = service().read(inst.id);
    expect(read, isNotNull);
    expect(read!.name, 'ZCode #2');
    expect(read.pid, isNull);
  });

  test('buildInstanceEnv：绑定账号后将快照写入实例数据目录并隔离 HOME', () async {
    _writeCurrentLogin(paths);
    final captured = await store.capture();
    final inst = await service().create(name: 'B1', bindAccountId: captured.id);

    final env = await service().buildInstanceEnv(inst.id);
    final dataDir = paths.instanceDataRoot(inst.id);
    final electronDir = p.join(paths.instanceRoot(inst.id), 'electron');
    final v2 = p.join(dataDir, '.zcode', 'v2');
    expect(File(p.join(v2, 'credentials.json')).existsSync(), isTrue);
    expect(env['HOME'], dataDir);
    // Electron 用户数据目录在 instance root/electron 下（与 Electron 版对齐）
    expect(env['ZCODE_DESKTOP_USER_DATA_DIR'], electronDir);
    expect(env['ZCODE_DESKTOP_SESSION_DATA_DIR'], p.join(electronDir, 'session'));
    expect(env['ZCODE_CREDENTIAL_SECRET'], isNotEmpty);

    // 实例内写入的登录态与快照一致
    final creds = jsonDecode(File(p.join(v2, 'credentials.json')).readAsStringSync());
    expect(creds['oauth:active_provider'], 'zai');
  });

  test('ensureSetup 创建默认实例', () async {
    await service().ensureSetup();
    expect(Directory(paths.instancesDir).existsSync(), isTrue);
    final dirs = Directory(paths.instancesDir).listSync().whereType<Directory>().toList();
    expect(dirs, hasLength(1));
  });
}
