import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/crypto.dart';
import 'core/paths.dart';
import 'platform/zcode_bridge.dart';
import 'services/account_store.dart';
import 'services/app_state.dart';
import 'services/bigmodel_key_service.dart';
import 'services/instance_service.dart';
import 'services/quota_service.dart';
import 'services/settings_store.dart';
import 'services/switcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final paths = AppPaths(zcasDataDir: Platform.environment['ZCAS_DATA_DIR']);
  final platform = ZCodePlatformBridge();

  // 凭据密钥以真实 home 派生（ZCode 的 enc:v1 与真实 home 绑定）。
  // env 优先级更高，天然兼容开发者手动设置 ZCODE_CREDENTIAL_SECRET 的情况。
  final identity = await platform.hostIdentity();
  if (identity != null && identity['home']?.isNotEmpty == true) {
    setDefaultCredentialSecretOverride(
      'zcode-credential-fallback:${defaultPlatformName()}:${identity['home']}:${identity['user'] ?? 'unknown'}',
    );
  }

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

  final services = AppServices(
    paths: paths,
    platform: platform,
    store: store,
    switcher: switcher,
    quota: quota,
    instances: instances,
    state: state,
    settings: settings,
  );

  runApp(ZcodeHelperApp(services: services));
}
