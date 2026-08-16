import 'package:flutter/foundation.dart';

import '../core/account_models.dart';
import '../core/fingerprint.dart';
import 'account_store.dart';
import 'instance_service.dart';

/// 全局共享的可观察状态（顶部状态条 + 各页面订阅）。
class AppState extends ChangeNotifier {
  AppState({
    required this.store,
    required this.instances,
  });

  final AccountStore store;
  final InstanceService instances;

  Fingerprint? current;
  List<RuntimeInstance> runningInstances = const [];
  DateTime? lastRefreshedAt;

  Future<void>? _refreshInFlight;

  /// 刷新当前账号与运行实例。进行中重复调用返回同一 Future，
  /// 避免 shell 定时刷新与页面手动刷新并发执行。
  Future<void> refresh() =>
      _refreshInFlight ??= _doRefresh().whenComplete(() => _refreshInFlight = null);

  Future<void> _doRefresh() async {
    try {
      current = await store.current();
    } catch (_) {
      current = null;
    }
    try {
      final all = await instances.list();
      runningInstances = all.where((i) => i.running).toList();
    } catch (_) {
      runningInstances = const [];
    }
    lastRefreshedAt = DateTime.now();
    notifyListeners();
  }
}
