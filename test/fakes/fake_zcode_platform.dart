import 'dart:async';

import 'package:zcode_helper/core/account_models.dart';
import 'package:zcode_helper/platform/zcode_bridge.dart';

/// 脚本化测试替身（原位于 lib/platform/zcode_bridge.dart，
/// 测试代码不得留在生产库里）。
class FakeZCodePlatform implements ZCodePlatform {
  FakeZCodePlatform({
    List<RuntimeProcess> running = const [],
  }) : running = List.of(running);

  List<RuntimeProcess> running;
  bool launchCalled = false;
  final List<int> terminated = [];
  String? lastOpenedUrl;
  Map<String, String>? identity;
  String? lastOAuthWindowUrl;
  final StreamController<String> _callbacks = StreamController.broadcast();
  final StreamController<void> _windowClosed = StreamController.broadcast();

  /// 模拟原生转发的 zcode:// 回调。
  void emitOAuthCallback(String url) => _callbacks.add(url);

  /// 模拟用户关闭 OAuth 登录窗口。
  void emitOAuthWindowClosed() => _windowClosed.add(null);

  @override
  Stream<String> oauthCallbackUrls() => _callbacks.stream;

  @override
  Stream<void> oauthWindowClosedEvents() => _windowClosed.stream;

  @override
  Future<bool> openOAuthWindow(String url, {String? title}) async {
    lastOAuthWindowUrl = url;
    return true;
  }

  @override
  Future<void> closeOAuthWindow() async {}

  @override
  Future<List<RuntimeProcess>> runningZcodeProcesses() async => List.of(running);

  @override
  Future<bool> launchZCode(String? exePath) async {
    launchCalled = true;
    return true;
  }

  @override
  Future<Map<int, bool>> terminatePids(List<int> pids) async {
    terminated.addAll(pids);
    running = running.where((p) => !pids.contains(p.pid)).toList();
    return {for (final pid in pids) pid: true};
  }

  @override
  Future<bool> openUrl(String url) async {
    lastOpenedUrl = url;
    return true;
  }

  @override
  Future<Map<String, String>?> hostIdentity() async => identity;
}
