import 'dart:async';

import 'package:flutter/services.dart';

import '../core/account_models.dart';
import '../services/app_log.dart';

/// 原生能力抽象。生产环境走 MethodChannel，测试注入替身
/// （test/fakes/fake_zcode_platform.dart）。
abstract class ZCodePlatform {
  Future<List<RuntimeProcess>> runningZcodeProcesses();

  Future<bool> launchZCode(String? exePath);

  /// 请求结束指定 PID。
  Future<Map<int, bool>> terminatePids(List<int> pids);

  /// 用系统浏览器打开 URL（OAuth 登录页）。
  Future<bool> openUrl(String url);

  /// 主机身份：真实 home 与用户名（凭据密钥按真实 home 派生）。
  Future<Map<String, String>?> hostIdentity();

  /// 打开应用内 OAuth 登录窗口（WKWebView 拦截 zcode:// 回调，
  /// 不经过系统协议路由，无需关闭运行中的 ZCode）。
  Future<bool> openOAuthWindow(String url, {String? title});

  /// 关闭应用内 OAuth 登录窗口（无窗口时为空操作）。
  Future<void> closeOAuthWindow();

  /// 原生转发的 zcode:// 回调 URL 事件流（OAuth 窗口拦截 / GURL 兜底）。
  Stream<String> oauthCallbackUrls();

  /// OAuth 登录窗口被用户关闭的事件流。
  Stream<void> oauthWindowClosedEvents();
}

class ZCodePlatformBridge implements ZCodePlatform {
  ZCodePlatformBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('zcode.helper/bridge') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOAuthCallback') {
        final url = (call.arguments as Map?)?['url'] as String?;
        // 回调 url 含授权码，日志只记长度。
        appLog('bridge', 'dart got onOAuthCallback (len=${url?.length ?? 0})');
        if (url != null && url.isNotEmpty) _callbacks.add(url);
      } else if (call.method == 'onOAuthWindowClosed') {
        appLog('bridge', 'dart got onOAuthWindowClosed');
        _windowClosed.add(null);
      }
      return null;
    });
  }

  final MethodChannel _channel;
  final StreamController<String> _callbacks = StreamController.broadcast();
  final StreamController<void> _windowClosed = StreamController.broadcast();

  @override
  Stream<String> oauthCallbackUrls() => _callbacks.stream;

  @override
  Stream<void> oauthWindowClosedEvents() => _windowClosed.stream;

  @override
  Future<bool> openOAuthWindow(String url, {String? title}) async {
    try {
      return await _channel.invokeMethod<bool>('openOAuthWindow', {
            'url': url,
            'title': title ?? '登录',
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> closeOAuthWindow() async {
    try {
      await _channel.invokeMethod<void>('closeOAuthWindow');
    } catch (_) {}
  }

  @override
  Future<List<RuntimeProcess>> runningZcodeProcesses() async {
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('listRunningZcode');
      if (list == null) return const [];
      return list.map((raw) {
        final m = (raw as Map).cast<String, dynamic>();
        return RuntimeProcess(
          pid: (m['pid'] as num?)?.toInt() ?? 0,
          name: m['name'] as String?,
          bundleId: m['bundleId'] as String?,
          path: m['path'] as String?,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> launchZCode(String? exePath) async {
    try {
      return await _channel.invokeMethod<bool>('launchZCode', {'path': exePath}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<int, bool>> terminatePids(List<int> pids) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('terminatePids', {'pids': pids});
      if (result == null) return {};
      return result.map((k, v) => MapEntry((k as num).toInt(), v == true));
    } catch (_) {
      return {};
    }
  }

  @override
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, String>?> hostIdentity() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('hostIdentity');
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return null;
    }
  }
}
