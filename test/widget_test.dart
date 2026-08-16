import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zcode_helper/app.dart';
import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/core/paths.dart';
import 'package:zcode_helper/services/account_store.dart';
import 'package:zcode_helper/services/app_state.dart';
import 'package:zcode_helper/services/bigmodel_key_service.dart';
import 'package:zcode_helper/services/instance_service.dart';
import 'package:zcode_helper/services/quota_service.dart';
import 'package:zcode_helper/services/settings_store.dart';
import 'package:zcode_helper/services/switcher.dart';
import 'package:zcode_helper/ui/account_card.dart';
import 'fakes/fake_zcode_platform.dart';

void main() {
  AppServices buildServices({required String home, required String zcas}) {
    final paths = AppPaths(home: home, zcasDataDir: zcas);
    final platform = FakeZCodePlatform();
    final store = AccountStore(paths);
    final keyService = BigModelKeyService();
    final switcher = SwitchController(
      paths: paths,
      platform: platform,
      deriveCodingPlanKey: keyService.resolveBigModelCodingPlanApiKey,
    );
    final quota = QuotaService();
    final instances = InstanceService(paths: paths, platform: platform, store: store);
    final state = AppState(store: store, instances: instances);
    final settings = SettingsStore(paths);
    return AppServices(
      paths: paths,
      platform: platform,
      store: store,
      switcher: switcher,
      quota: quota,
      instances: instances,
      state: state,
      settings: settings,
    );
  }

  testWidgets('应用冒烟：三页可渲染，顶部状态条存在', (tester) async {
    final tempHome = Directory.systemTemp.createTempSync('zcas-wt-home-');
    final tempZcas = Directory.systemTemp.createTempSync('zcas-wt-');
    addTearDown(() {
      for (final d in [tempHome, tempZcas]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    final services = buildServices(home: tempHome.path, zcas: tempZcas.path);

    await tester.pumpWidget(ZcodeHelperApp(services: services));
    await tester.pump();

    // 状态条
    expect(find.text('主目录'), findsOneWidget);
    expect(find.text('运行实例'), findsOneWidget);

    // 账号页
    expect(find.text('账号快照'), findsOneWidget);
    expect(find.text('捕获当前账号'), findsOneWidget);

    // 切到实例页（800px 下侧栏为折叠图标模式）
    await tester.tap(find.byIcon(Icons.terminal_rounded));
    await tester.pumpAndSettle();
    expect(find.text('多开实例'), findsOneWidget);

    // 切到设置页
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();
    expect(find.text('数据目录'), findsOneWidget);
    // 「关于」在列表底部，先滚动到可见
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);

    // 卸载树以便取消周期定时器
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('响应式冒烟：窄窗口下侧栏收成图标、状态条双行、无溢出', (tester) async {
    final tempHome = Directory.systemTemp.createTempSync('zcas-wt-narrow-home-');
    final tempZcas = Directory.systemTemp.createTempSync('zcas-wt-narrow-');
    addTearDown(() {
      for (final d in [tempHome, tempZcas]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final services = buildServices(home: tempHome.path, zcas: tempZcas.path);

    await tester.pumpWidget(ZcodeHelperApp(services: services));
    await tester.pump();

    // 状态条两段仍在（窄窗口双行布局）
    expect(find.text('主目录'), findsOneWidget);
    expect(find.text('运行实例'), findsOneWidget);

    // 账号页可渲染，工具按钮仍在
    expect(find.text('账号快照'), findsOneWidget);
    expect(find.text('捕获当前账号'), findsOneWidget);

    // 侧栏收成纯图标：文字标签不再显示
    expect(find.text('账号'), findsNothing);
    await tester.tap(find.byIcon(Icons.terminal_rounded));
    await tester.pumpAndSettle();
    expect(find.text('多开实例'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();
    expect(find.text('数据目录'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('主题切换：设置页选择深色/浅色后立即生效并持久化', (tester) async {
    final tempHome = Directory.systemTemp.createTempSync('zcas-wt-theme-home-');
    final tempZcas = Directory.systemTemp.createTempSync('zcas-wt-theme-');
    addTearDown(() {
      for (final d in [tempHome, tempZcas]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    final services = buildServices(home: tempHome.path, zcas: tempZcas.path);

    await tester.pumpWidget(ZcodeHelperApp(services: services));
    await tester.pump();

    // 切到设置页
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsOneWidget);

    // 测试环境平台亮度为 light，选择「深色」后 MaterialApp 应切到 dark 主题
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(services.settings.value, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.dark,
    );

    // 切回「浅色」
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(services.settings.value, ThemeMode.light);
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.light,
    );

    // 持久化校验：重建 SettingsStore 能读回 light
    expect(SettingsStore(services.paths).value, ThemeMode.light);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('账号卡片：最坏内容（套餐+3条额度+告警摘要）在固定高度内不溢出', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = AccountEntry(
      meta: AccountMeta(
        id: 'acc-1',
        userId: 'user-id-1234567890',
        provider: 'zai',
        email: 'someone@example.com',
        capturedAt: now,
      ),
      sizeKb: 2,
      health: const AccountHealth(
        status: 'warning',
        summary: '这是一段比较长的健康摘要文本，用于验证在固定卡片高度内会按省略号截断而不是溢出布局。',
      ),
    );
    final quota = QuotaOverview(
      status: 'ok',
      provider: 'zai',
      plan: const PlanTierInfo(tier: 'plus', label: 'Coding Plus', isPlan: true, isPlus: true, isPro: false, billingCycle: '月付'),
      items: [
        for (var i = 0; i < 5; i++)
          QuotaItem(
            label: '5 小时窗口额度项 $i',
            used: 30,
            quota: 120,
            percent: 0.25,
            status: 'healthy',
            resetAt: now + 3600000,
          ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 330,
                height: 344,
              child: AccountCard(
                entry: entry,
                quota: quota,
                onSwitch: () {},
                onRename: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 框架在溢出时会抛异常导致测试失败；这里显式确认按钮渲染完整
    expect(find.text('切换并重启'), findsOneWidget);
  });

  testWidgets('回归：最小窗口（480x480）有账号快照时整页无溢出', (tester) async {
    tester.view.physicalSize = const Size(480, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tempHome = Directory.systemTemp.createTempSync('zcas-wt-min-home-');
    final tempZcas = Directory.systemTemp.createTempSync('zcas-wt-min-');
    addTearDown(() {
      for (final d in [tempHome, tempZcas]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    final services = buildServices(home: tempHome.path, zcas: tempZcas.path);
    // 造一份登录态并捕获，让账号页渲染真实卡片
    final v2 = Directory(p.join(tempHome.path, '.zcode', 'v2'))..createSync(recursive: true);
    File(p.join(v2.path, 'credentials.json')).writeAsStringSync(jsonEncode({
      'zai': {'access_token': 'eyJhbGciOiJIUzI1NiJ9.e30.sig'},
    }));
    File(p.join(v2.path, 'config.json')).writeAsStringSync('{}');
    await services.store.capture();

    await tester.pumpWidget(ZcodeHelperApp(services: services));
    await tester.pump();
    // 等一轮状态刷新（状态条 5s 轮询不触发，等 1s 的额度异步即可）
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('账号快照'), findsOneWidget);
    expect(find.text('切换并重启'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
