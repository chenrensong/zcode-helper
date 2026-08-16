import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/account_models.dart';
import '../core/paths.dart';
import '../platform/zcode_bridge.dart';
import 'account_store.dart';
import 'app_log.dart';
import 'bigmodel_key_service.dart';
import 'oauth_service.dart';
import 'oauth_writer.dart';
import 'switcher.dart';

/// OAuth 登录编排（应用内 WKWebView 窗口，零打扰）：
///
/// 中转页 zcode.z.ai/app/oauth/login 会校验 redirect 参数，只接受
/// `zcode://oauth/callback`。回调在应用内 OAuth 窗口的导航决策层被直接
/// 拦截（不经系统协议路由），因此登录全程：
///   - 不关闭运行中的 ZCode（协议接管方案必须杀进程，本方案不需要）
///   - 不接管/恢复 zcode:// 默认处理器
///   - 写盘在临时目录完成（种子自当前 live 文件），快照直接入库真实
///     仓库；live 主目录全程零改动，无需还原现场，也不存在运行中的
///     ZCode 读到中间态的竞态窗口。
/// 流程：state → 应用内窗口登录 → 拦截回调校验 state → 换 token →
/// 业务登录（zai）→ 临时目录写盘 + 捕获快照。关闭登录窗口即取消。
class LoginController {
  LoginController({
    required this.paths,
    required this.platform,
    required this.store,
    OAuthService? oauth,
    BigModelKeyService? keyService,
    this.timeout = const Duration(minutes: 10),
  })  : _oauth = oauth ?? OAuthService(),
        _keyService = keyService ?? BigModelKeyService();

  final AppPaths paths;
  final ZCodePlatform platform;
  final AccountStore store;
  final OAuthService _oauth;
  final BigModelKeyService _keyService;
  final Duration timeout;

  Completer<String?>? _manualCode;

  /// 手动粘贴授权码（等回调阶段 UI 调用）。
  void submitManualCode(String code) {
    final m = _manualCode;
    final trimmed = code.trim();
    if (m != null && !m.isCompleted && trimmed.isNotEmpty) {
      m.complete(trimmed);
    }
  }

  /// 登录不杀进程、不动协议：应用内窗口完成 OAuth（详见类注释）。
  ///
  /// 执行一次完整登录。provider: 'zai' | 'bigmodel'。
  Future<LoginResult> login({
    required String provider,
    bool overwrite = false,
    LoginPhaseHandler? onPhase,
    bool Function()? isCancelled,
  }) async {
    final isBig = provider == 'bigmodel';
    void phase(LoginPhase p, String msg) => onPhase?.call(p, msg);
    _manualCode = Completer<String?>();
    try {
      appLog('login', 'start provider=$provider');
      phase(LoginPhase.preparing, '正在准备登录…');
      final state = _randomHex(16);
      final url = _oauth.buildAuthorizeUrl(state, provider);
      // 不记完整 authorize url（含 state），只记 provider 便于排查。
      appLog('login', 'authorize url ready (provider=$provider)');

      phase(
        LoginPhase.browserOpen,
        provider == 'bigmodel'
            ? '请在弹出的窗口中登录 BigModel（中国区）账号'
            : '请在弹出的窗口中登录 Z.ai（全球区）账号',
      );
      final opened = await platform.openOAuthWindow(url, title: '登录 ${provider == 'bigmodel' ? 'BigModel' : 'Z.ai'} 账号');
      appLog('login', 'oauth window opened=$opened');
      if (!opened) {
        throw SwitchError('无法打开登录窗口，请重试');
      }

      phase(
        LoginPhase.waiting,
        '登录完成后将自动继续；关闭登录窗口即取消。',
      );
      final code = await _waitForCode(
        state: state,
        manual: _manualCode!,
        isCancelled: isCancelled,
      );
      appLog('login', 'code obtained (len=${code.length})');

      phase(LoginPhase.exchanging, '登录成功，正在换发令牌…');
      final tokenSet = await _oauth.exchangeCode(code, state, provider);

      // zai：业务登录，换取业务 JWT（billing plan 初始化依赖它）。
      if (!isBig && tokenSet.zaiAccessToken != null) {
        final businessJwt = await _oauth.exchangeBusinessToken(tokenSet.zaiAccessToken!);
        if (businessJwt != null) {
          tokenSet.zaiAccessToken = businessJwt;
        }
      }

      phase(LoginPhase.saving, '正在写入登录态并捕获账号…');
      final userInfo = isBig
          ? toNativeBigModelUserProfile(tokenSet.user)
          : normalizeUserInfo(tokenSet.user);

      final captured = await _captureInTempDir(
        tokenSet: tokenSet,
        userInfo: userInfo,
        provider: provider,
        deriveCodingPlanKey: isBig,
        overwrite: overwrite,
      );

      phase(LoginPhase.done, '保存完成');
      appLog('login', 'done account=${captured.meta?.label}');
      return LoginResult(
        provider: provider,
        account: captured.meta,
        created: captured.created,
        skipped: captured.skipped,
        // bigmodel 原生 profile 无 email 字段，回退到原始 user 信息。
        email: (userInfo['email'] as String?) ?? (tokenSet.user['email'] as String?),
        name: (userInfo['name'] as String?) ?? (tokenSet.user['name'] as String?),
      );
    } on SwitchAborted {
      appLog('login', 'aborted');
      rethrow;
    } on SwitchError catch (e) {
      appLog('login', 'error: ${e.message}');
      rethrow;
    } catch (e) {
      appLog('login', 'error: $e');
      rethrow;
    } finally {
      final manual = _manualCode;
      if (manual != null && !manual.isCompleted) manual.complete(null);
      _manualCode = null;
      await platform.closeOAuthWindow();
    }
  }

  Future<String> _waitForCode({
    required String state,
    required Completer<String?> manual,
    bool Function()? isCancelled,
  }) async {
    final codeCompleter = Completer<String>();
    late final StreamSubscription<String> sub;
    late final StreamSubscription<void> closedSub;
    sub = platform.oauthCallbackUrls().listen(
      (rawUrl) {
        // 回调 url 含授权码，不写日志；state 校验通过与否在下方体现。
        appLog('login', 'callback received');
        if (codeCompleter.isCompleted) return;
        final uri = Uri.tryParse(rawUrl);
        if (uri == null) return;
        final code = uri.queryParameters['code'] ?? uri.queryParameters['authCode'];
        final cbState = uri.queryParameters['state'];
        // 只认本会话发起的回调（防串扰 / 重放），浏览器可能重复触发。
        if (code != null && code.isNotEmpty && cbState == state) {
          codeCompleter.complete(code);
        }
      },
    );
    closedSub = platform.oauthWindowClosedEvents().listen((_) {
      if (!codeCompleter.isCompleted) {
        codeCompleter.completeError(SwitchAborted());
      }
    });
    try {
      final deadline = DateTime.now().add(timeout);
      while (true) {
        if (isCancelled?.call() ?? false) throw SwitchAborted();
        if (manual.isCompleted) {
          final m = await manual.future;
          if (m == null || m.isEmpty) throw SwitchAborted();
          return m;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw SwitchError('登录超时（${timeout.inMinutes} 分钟），请重试');
        }
        try {
          return await codeCompleter.future.timeout(const Duration(milliseconds: 300));
        } on TimeoutException {
          continue;
        }
      }
    } finally {
      await sub.cancel();
      await closedSub.cancel();
    }
  }

  void close() => _oauth.close();

  /// 临时目录写盘 + 捕获：live 主目录零改动。
  ///
  /// 临时 home 以当前 live 文件为种子（保留非 OAuth 字段），OAuthWriter
  /// 在临时目录完成写盘；通过 zcasDataDir 指回真实仓库根，快照直接入库。
  Future<CaptureResult> _captureInTempDir({
    required OAuthTokenSet tokenSet,
    required Map<String, dynamic> userInfo,
    required String provider,
    required bool deriveCodingPlanKey,
    required bool overwrite,
  }) async {
    final tempHome = Directory.systemTemp.createTempSync('zcas-login-');
    try {
      final tempV2 = Directory(p.join(tempHome.path, '.zcode', 'v2'))
        ..createSync(recursive: true);
      for (final src in [paths.credentialsFile, paths.configFile, paths.settingFile]) {
        final f = File(src);
        if (f.existsSync()) f.copySync(p.join(tempV2.path, p.basename(src)));
      }
      final tempPaths = AppPaths(home: tempHome.path, zcasDataDir: paths.zcasRoot);
      final writer = OAuthWriter(tempPaths);
      await writer.writeCredentials(
        tokenSet: tokenSet,
        userInfo: userInfo,
        provider: provider,
      );
      if (deriveCodingPlanKey && tokenSet.zaiAccessToken != null) {
        final derived = await _keyService.resolveBigModelCodingPlanApiKey(
          tokenSet.zaiAccessToken!,
        );
        if (derived != null) writer.applyCodingPlanApiKey(derived);
      }
      return await AccountStore(tempPaths).capture(overwrite: overwrite);
    } finally {
      try {
        tempHome.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  String _randomHex(int bytes) {
    final rand = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(rand.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
