import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/account_models.dart';
import '../core/core.dart';
import '../core/crypto.dart';
import 'tokens.dart';

const String _billingCurrentUrl = 'https://zcode.z.ai/api/v1/zcode-plan/billing/current';
const String _billingBalanceUrl = 'https://zcode.z.ai/api/v1/zcode-plan/billing/balance';
const String _bigModelQuotaUrl = 'https://open.bigmodel.cn/api/monitor/usage/quota/limit';
const String _zaiQuotaUrl = 'https://api.z.ai/api/monitor/usage/quota/limit';

// ZCode 客户端请求 billing/current 时带 app_version + platform 参数，
// 服务端根据这些参数路由到正确的 billing plan 版本；
// 缺少参数时服务端可能返回空 plans（新账号场景下尤为明显）。
const String _clientAppVersion = '4.1.10';
const String _clientPlatform = 'win32-x64';

/// billing 端点不支持（405 / code:3012），账号无 Coding Plan。
class _BillingUnsupported implements Exception {
  const _BillingUnsupported();
}

/// 额度查询：
/// - BigModel：open.bigmodel.cn quota/limit（access_token 鉴权，不加 Bearer）
/// - Z.ai：优先 api.z.ai quota/limit（同格式），兜底 zcode.z.ai billing/current+balance
///   （Bearer zcodejwttoken，app_version/platform 参数 + 429 退避）
class QuotaService {
  QuotaService({http.Client? client, this.timeoutSecs = 12, String? secret})
      : _client = client ?? http.Client(),
        _defaultSecret = secret;

  final http.Client _client;
  final int timeoutSecs;
  final String? _defaultSecret;

  /// 当前运行态（未切换文件）查询入口。
  Future<QuotaOverview> overviewFromCurrentFiles(
    String credentialsFile,
    String configFile, {
    String? secret,
  }) async {
    final s = secret ?? _defaultSecret;
    Map<String, dynamic> credentials = {};
    try {
      credentials = jsonDecode(File(credentialsFile).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    final tokens = await readCandidateTokensFromFiles(credentialsFile, configFile, secret: s);
    return _overview(credentials: credentials, tokens: tokens, secret: s);
  }

  /// 快照查询入口。
  Future<QuotaOverview> overviewFromSnapshot(
    Snapshot? snapshot, {
    String? secret,
  }) async {
    final s = secret ?? _defaultSecret;
    Map<String, dynamic> credentials = {};
    if (snapshot != null) {
      try {
        credentials = jsonDecode(snapshot.credentials) as Map<String, dynamic>;
      } catch (_) {}
    }
    final tokens = await readCandidateTokensFromSnapshot(snapshot, secret: s);
    return _overview(credentials: credentials, tokens: tokens, secret: s);
  }

  /// 仅凭候选 token 走 billing 兜底链路。
  Future<QuotaOverview> getQuotaOverview(List<String> tokens, {String? secret}) {
    return _queryByTokens(tokens);
  }

  Future<QuotaOverview> _overview({
    required Map<String, dynamic> credentials,
    required List<String> tokens,
    String? secret,
  }) async {
    final provider = (await safeDecrypt(credentials['oauth:active_provider'], secret: secret)) ?? 'zai';

    if (provider == 'bigmodel') {
      final accessToken = await safeDecrypt(credentials['oauth:bigmodel:access_token'], secret: secret);
      if (accessToken == null || accessToken.isEmpty) {
        return overviewError('未找到 BigModel access_token，请先登录');
      }
      return await _queryQuotaLimit(_bigModelQuotaUrl, accessToken, provider: 'bigmodel');
    }

    // Z.ai：优先 api.z.ai 的 quota/limit（与 BigModel 同格式），失败兜底 billing。
    final zaiToken = await safeDecrypt(credentials['oauth:zai:access_token'], secret: secret);
    if (zaiToken != null && zaiToken.isNotEmpty) {
      final result = await _tryZaiQuotaLimit(zaiToken);
      if (result != null) return result;
    }

    if (tokens.isEmpty) {
      return overviewError('未找到可用于查询额度的 ZCode token，请先登录或切换账号');
    }
    return _queryByTokens(tokens);
  }

  // ---- quota/limit（BigModel / Z.ai 同格式：data.limits + data.level） ----

  /// BigModel 专用：任何失败都作为错误结果返回（无兜底链路）。
  Future<QuotaOverview> _queryQuotaLimit(String url, String token, {required String provider}) async {
    try {
      final res = await _client
          .get(
            Uri.parse(url),
            headers: {'accept': 'application/json', 'authorization': token},
          )
          .timeout(Duration(seconds: timeoutSecs));
      if (res.statusCode == 401 || res.statusCode == 403) {
        return overviewError('$provider Token 已过期或无效（HTTP ${res.statusCode}）');
      }
      if (res.statusCode != 200) {
        return overviewError('$provider 额度查询失败 HTTP ${res.statusCode}');
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return overviewError('$provider 额度查询失败');
      final code = decoded['code'];
      final msg = decoded['msg']?.toString() ?? '';
      // code=500 + "当前用户不存在coding plan" → 无 Coding Plan
      if (code == 500 && RegExp('不存在.*plan', caseSensitive: false).hasMatch(msg)) {
        return _noPlan();
      }
      if (code == 401) return overviewError('$provider Token 已过期或无效');
      if (code != null && code != 200 && code != 0 && decoded['success'] != true) {
        return overviewError(firstText([decoded['msg'], '$provider 额度查询失败']) ?? '$provider 额度查询失败');
      }
      return _normalizeQuotaLimit(decoded['data'], provider);
    } catch (e) {
      return overviewError('$provider 额度查询失败：$e');
    }
  }

  /// Z.ai 优先链路：任何失败返回 null，交由 billing 兜底。
  Future<QuotaOverview?> _tryZaiQuotaLimit(String token) async {
    final result = await _queryQuotaLimit(_zaiQuotaUrl, token, provider: 'Z.ai');
    return result.isOk ? result : null;
  }

  /// limits[] → 展示项。unit 枚举（逆向自 BigModel/Z.ai API）：3=小时 5=月 6=周。
  QuotaOverview _normalizeQuotaLimit(Object? data, String provider) {
    final map = data is Map ? data : <String, dynamic>{};
    final limits = map['limits'] is List ? map['limits'] as List : [];
    final level = map['level']?.toString() ?? '';

    final tokenLimits = limits
        .whereType<Map>()
        .where((l) => l['type'] == 'TOKENS_LIMIT')
        .toList()
      ..sort((a, b) => (toNum(a['nextResetTime']) ?? 0).compareTo(toNum(b['nextResetTime']) ?? 0));
    final timeLimits = limits.whereType<Map>().where((l) => l['type'] == 'TIME_LIMIT').toList();

    String periodLabel(Map l) {
      const unitMap = {3: '小时', 5: '月', 6: '周'};
      final unit = toNum(l['unit'])?.toInt();
      final u = unit != null ? unitMap[unit] : null;
      final n = l['number']?.toString() ?? '';
      if (u != null && u.isNotEmpty && n.isNotEmpty) return '$n$u';
      return u ?? '';
    }

    final items = <QuotaItem>[];
    String prefix = level.isNotEmpty ? '${level.toUpperCase()} · ' : '';

    // 5 小时滚动窗口（第一个 TOKENS_LIMIT）+ 每周额度（第二个）
    for (var i = 0; i < tokenLimits.length && i < 2; i++) {
      final limit = tokenLimits[i];
      final period = periodLabel(limit).isNotEmpty
          ? periodLabel(limit)
          : (i == 0 ? '5小时' : '每周');
      final percent = toNum(limit['percentage']) ?? 0;
      items.add(_makePercentItem(
        '$prefix$period剩余',
        percent,
        resetAt: toNum(limit['nextResetTime'])?.toInt(),
        raw: limit,
      ));
    }

    // MCP/时间限制
    if (timeLimits.isNotEmpty) {
      final mcp = timeLimits.first;
      final period = periodLabel(mcp).isNotEmpty ? periodLabel(mcp) : '月';
      final quota = toNum(mcp['usage']) ?? 100;
      final used = toNum(mcp['currentValue']) ?? toNum(mcp['percentage']) ?? 0;
      items.add(_makeCountItem(
        'MCP $period剩余',
        used,
        quota,
        resetAt: toNum(mcp['nextResetTime'])?.toInt(),
        raw: mcp,
      ));
    }

    if (items.isEmpty) return _noPlan();

    final tier = level.toLowerCase();
    return QuotaOverview(
      provider: provider == 'Z.ai' ? 'zai' : provider,
      status: 'ok',
      plan: level.isEmpty
          ? null
          : PlanTierInfo(
              tier: tier,
              label: level[0].toUpperCase() + level.substring(1),
              isPlan: true,
              isPlus: tier == 'plus' || tier == 'max',
              isPro: tier == 'pro',
            ),
      items: items,
      raw: {'limits': limits, 'level': level},
    );
  }

  // ---- billing 兜底（Z.ai zcodejwttoken） ----

  Future<QuotaOverview> _queryByTokens(List<String> tokens) async {
    Object? lastError;
    var authFailCount = 0;
    for (final token in tokens) {
      try {
        return await _fetchBillingOverview(token);
      } on _BillingUnsupported {
        return _noPlan();
      } catch (e) {
        lastError = e;
        // 401/403 计数：所有候选 token 都鉴权失败 → token 整体过期
        if (RegExp('HTTP 40[13]').hasMatch(e.toString())) authFailCount++;
      }
    }

    // 全部 401/403：可能是服务端首次激活延迟，等 1.5s 用第一个 token 重试一次
    if (authFailCount > 0 && authFailCount == tokens.length && tokens.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      try {
        return await _fetchBillingOverview(tokens.first);
      } catch (e) {
        lastError = e;
      }
      return overviewError('该账号 Token 已过期，请删除后重新登录');
    }
    return overviewError(lastError?.toString() ?? '额度查询失败');
  }

  Future<QuotaOverview> _fetchBillingOverview(String token) async {
    final current = await _fetchBilling(_billingCurrentUrl, token);
    final balance = await _fetchBilling(_billingBalanceUrl, token);
    return _normalizeBillingQuota(current, balance);
  }

  /// billing 请求：429 退避（500ms/1.5s/4s）、401/403 友好提示、405/3012 → 无 Plan。
  Future<dynamic> _fetchBilling(String baseUrl, String token) async {
    final url = Uri.parse(baseUrl).replace(queryParameters: {
      'app_version': _clientAppVersion,
      'platform': _clientPlatform,
    });
    const retryDelays = [500, 1500, 4000];
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      final res = await _client
          .get(
            url,
            headers: {
              'accept': 'application/json, text/plain, */*',
              'authorization': 'Bearer $token',
            },
          )
          .timeout(Duration(seconds: timeoutSecs));
      dynamic data;
      try {
        data = res.body.isEmpty ? null : jsonDecode(res.body);
      } catch (_) {
        data = res.body;
      }
      if (res.statusCode == 200) return data;

      if (res.statusCode == 429 && attempt < retryDelays.length) {
        await Future<void>.delayed(Duration(milliseconds: retryDelays[attempt]));
        continue;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw Exception('Token 已过期或无效（HTTP ${res.statusCode}）');
      }
      final msg = data is Map ? firstText([data['message'], data['msg'], data['error']]) : data?.toString();
      if (res.statusCode == 405 || (data is Map && data['code'] == 3012)) {
        throw const _BillingUnsupported();
      }
      throw Exception('额度接口 HTTP ${res.statusCode}: ${msg ?? ''}');
    }
    throw Exception('额度查询失败');
  }

  /// billing/current + billing/balance → 统一概览（对齐 quota.js normalizeQuota）。
  QuotaOverview _normalizeBillingQuota(dynamic currentData, dynamic balanceData) {
    final current = _unwrap(currentData);
    final balance = _unwrap(balanceData);
    final pool = _flattenNumbers({'current': current, 'balance': balance});

    double? total = _sumNumbers(pool, ['total_units']) ??
        _firstNumber(pool, ['total', 'totalQuota', 'totalCredits', 'quotaTotal', 'amountTotal', 'creditTotal']);
    double? used = _sumNumbers(pool, ['used_units']) ??
        _firstNumber(pool, ['used', 'usedQuota', 'usedCredits', 'quotaUsed', 'amountUsed', 'consumed', 'totalUsed']);
    double? remaining = _sumNumbers(pool, ['remaining_units']) ??
        _firstNumber(pool, ['remaining', 'remain', 'balance', 'available', 'availableQuota', 'left', 'quotaRemaining']);

    if (total == null && used != null && remaining != null) total = used + remaining;
    if (used == null && total != null && remaining != null) used = max(0, total - remaining);
    if (remaining == null && total != null && used != null) remaining = max(0, total - used);

    // plans 与 balances 都为空 → 账号无套餐数据
    final plansEmpty = current is Map && current['plans'] is List && (current['plans'] as List).isEmpty;
    final balancesEmpty = balance is Map && balance['balances'] is List && (balance['balances'] as List).isEmpty;
    if (plansEmpty && balancesEmpty && total == null && used == null) {
      return _noPlan();
    }

    // 汇总条（与 Electron 版对齐：balances 明细优先，无明细但有总额时展示汇总）
    final items = <QuotaItem>[];
    if (balance is Map && balance['balances'] is List) {
      for (final raw in balance['balances'] as List) {
        if (raw is! Map) continue;
        final itemTotal = toNum(raw['total_units']);
        final itemUsed = toNum(raw['used_units']);
        final label = firstText([
          raw['show_name'],
          raw['name'],
          raw['entitlement_id'],
          raw['plan_id'],
        ]) ?? '未知模型';
        if (itemTotal == null && itemUsed == null) continue;
        items.add(_makeCountItem(
          '$label 剩余',
          itemUsed ?? 0,
          itemTotal ?? (itemUsed ?? 0),
          resetAt: _toEpochMs(firstText([raw['period_end'], raw['expires_at']])),
        ));
      }
    }
    if (items.isEmpty && total != null && total > 0) {
      items.add(_makeCountItem('剩余额度', used ?? 0, total, kind: 'quota'));
    }

    return QuotaOverview(
      provider: 'zai',
      status: 'ok',
      plan: _extractPlanTier(currentData),
      items: items,
      balance: remaining,
      cycleEnd: balance is Map ? firstText([balance['period_end'], balance['expires_at']]) : null,
      raw: {'current': currentData, 'balance': balanceData},
    );
  }

  /// billing/current 的 plans 数组提取付费等级（Max > Pro > Lite > Start Plan）。
  PlanTierInfo? _extractPlanTier(dynamic currentData) {
    final cur = _unwrap(currentData);
    if (cur is! Map || cur['plans'] is! List) return null;
    final active = (cur['plans'] as List)
        .whereType<Map>()
        .where((p) => p['status']?.toString().toLowerCase() == 'active')
        .toList();
    if (active.isEmpty) return null;

    bool matchKey(Map p, String kw) {
      final id = p['plan_id']?.toString().toLowerCase() ?? '';
      final name = p['name']?.toString().toLowerCase() ?? '';
      return id.contains(kw) || name.contains(kw);
    }

    String tier;
    if (active.any((p) => matchKey(p, 'max'))) {
      tier = 'max';
    } else if (active.any((p) => matchKey(p, 'pro'))) {
      tier = 'pro';
    } else if (active.any((p) => matchKey(p, 'lite'))) {
      tier = 'lite';
    } else if (active.any((p) => matchKey(p, 'start-plan') || matchKey(p, 'start plan'))) {
      tier = 'start';
    } else {
      return null;
    }
    final label = tier == 'start' ? 'Start Plan' : tier[0].toUpperCase() + tier.substring(1);
    return PlanTierInfo(
      tier: tier,
      label: label,
      isPlan: true,
      isPlus: tier == 'max' || tier == 'plus',
      isPro: tier == 'pro',
    );
  }

  /// 展开嵌套对象中的数字（路径末段作为 key 名匹配）。
  Map<String, double> _flattenNumbers(Object? obj) {
    final out = <String, double>{};
    void walk(Object? o, String path) {
      if (o is Map) {
        for (final e in o.entries) {
          final p = path.isEmpty ? '${e.key}' : '$path.${e.key}';
          final n = toNum(e.value);
          if (n != null) {
            out[p] = n;
          } else if (e.value is Map || e.value is List) {
            walk(e.value, p);
          }
        }
      } else if (o is List) {
        for (var i = 0; i < o.length; i++) {
          walk(o[i], '$path[$i]');
        }
      }
    }

    walk(obj, '');
    return out;
  }

  double? _firstNumber(Map<String, double> pool, List<String> keys) {
    for (final entry in pool.entries) {
      final name = entry.key.split('.').last.replaceAll(RegExp(r'\[\d+\]$'), '');
      if (keys.contains(name)) return entry.value;
    }
    return null;
  }

  double? _sumNumbers(Map<String, double> pool, List<String> keys) {
    var total = 0.0;
    var count = 0;
    for (final entry in pool.entries) {
      final name = entry.key.split('.').last.replaceAll(RegExp(r'\[\d+\]$'), '');
      if (keys.contains(name)) {
        total += entry.value;
        count++;
      }
    }
    return count > 0 ? total : null;
  }

  // ---- 展示项构造 ----

  QuotaItem _makePercentItem(String label, double percent, {int? resetAt, Object? raw}) {
    return QuotaItem(
      label: label,
      used: (percent * 10).roundToDouble() / 10,
      quota: 100,
      percent: clampNum(percent, 0, 100),
      status: _statusOf(percent),
      kind: 'quota_limit',
      resetAt: resetAt,
      raw: raw,
    );
  }

  QuotaItem _makeCountItem(String label, double used, double quota, {String kind = 'quota', int? resetAt, Object? raw}) {
    final percent = quota > 0 ? used / quota * 100 : 0.0;
    return QuotaItem(
      label: label,
      used: (used * 10).roundToDouble() / 10,
      quota: (quota * 10).roundToDouble() / 10,
      percent: clampNum(percent, 0, 100),
      status: _statusOf(percent),
      kind: kind,
      resetAt: resetAt,
      raw: raw,
    );
  }

  /// period_end / expires_at 兼容毫秒时间戳与 ISO 字符串两种格式。
  int? _toEpochMs(String? value) {
    if (value == null || value.isEmpty) return null;
    final n = toNum(value);
    if (n != null) return n.toInt();
    return DateTime.tryParse(value)?.millisecondsSinceEpoch;
  }

  String _statusOf(double percent) {
    if (percent >= 100) return 'exhausted';
    if (percent >= 80) return 'low';
    if (percent >= 50) return 'warning';
    return 'healthy';
  }

  QuotaOverview _noPlan() {
    return QuotaOverview(
      provider: 'unknown',
      status: 'noop',
      error: '该账号无 Coding Plan',
      items: const [],
    );
  }

  dynamic _unwrap(dynamic data) {
    var cur = data;
    for (var i = 0; i < 4; i++) {
      if (cur is! Map) break;
      if (cur.containsKey('data')) {
        cur = cur['data'];
        continue;
      }
      if (cur.containsKey('result')) {
        cur = cur['result'];
        continue;
      }
      break;
    }
    return cur;
  }
}

QuotaOverview overviewError(String message, {Object? raw}) {
  return QuotaOverview(
    provider: 'unknown',
    status: 'error',
    error: message,
    items: const [],
    raw: raw,
  );
}
