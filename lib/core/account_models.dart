/// 领域模型：账号快照、健康、额度、切换阶段与运行实例。
library;

class Snapshot {
  const Snapshot({required this.credentials, required this.config});

  final String credentials;
  final String config;

  Map<String, dynamic> toJson() => {'credentials': credentials, 'config': config};

  static Snapshot? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final c = json['credentials'];
    final g = json['config'];
    if (c is! String || g is! String) return null;
    return Snapshot(credentials: c, config: g);
  }
}

class AccountMeta {
  const AccountMeta({
    required this.id,
    this.shortId,
    this.emailShortId,
    this.userId,
    this.provider,
    this.label,
    this.email,
    this.name,
    this.avatar,
    this.customerId,
    this.userKey,
    this.source,
    this.note,
    this.capturedAt,
  });

  final String id;
  final String? shortId;
  final String? emailShortId;
  final String? userId;
  final String? provider;
  final String? label;
  final String? email;
  final String? name;
  final String? avatar;
  final String? customerId;
  final String? userKey;
  final String? source;
  final String? note;
  final int? capturedAt;

  String get displayLabel => (label?.isNotEmpty == true)
      ? label!
      : (email?.isNotEmpty == true)
          ? email!
          : (name?.isNotEmpty == true)
              ? name!
              : '账号-$id';

  String get shortLabel {
    final l = displayLabel;
    if (l.length <= 22) return l;
    return '${l.substring(0, 22)}…';
  }

  String get providerSymbol {
    final p = (provider ?? '').toLowerCase();
    if (p.contains('bigmodel')) return 'B';
    if (p.contains('zai')) return 'Z';
    return '?';
  }

  factory AccountMeta.fromJson(Map<String, dynamic> json) => AccountMeta(
        id: json['id'] as String,
        shortId: json['shortId'] as String?,
        emailShortId: json['emailShortId'] as String?,
        userId: json['userId'] as String?,
        provider: json['provider'] as String?,
        label: json['label'] as String?,
        email: json['email'] as String?,
        name: json['name'] as String?,
        avatar: json['avatar'] as String?,
        customerId: json['customerId'] as String?,
        userKey: json['userKey'] as String?,
        source: json['source'] as String?,
        note: json['note'] as String?,
        capturedAt: json['capturedAt'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (shortId != null) 'shortId': shortId,
        if (emailShortId != null) 'emailShortId': emailShortId,
        if (userId != null) 'userId': userId,
        if (provider != null) 'provider': provider,
        if (label != null) 'label': label,
        if (email != null) 'email': email,
        if (name != null) 'name': name,
        if (avatar != null) 'avatar': avatar,
        if (customerId != null) 'customerId': customerId,
        if (userKey != null) 'userKey': userKey,
        if (source != null) 'source': source,
        if (note != null) 'note': note,
        if (capturedAt != null) 'capturedAt': capturedAt,
      };
}

class AccountHealth {
  const AccountHealth({
    required this.status,
    required this.summary,
    this.warnings = const [],
    this.errors = const [],
    this.details = const {},
  });

  final String status; // healthy | warning | error
  final String summary;
  final List<String> warnings;
  final List<String> errors;
  final Map<String, dynamic> details;

  bool get isOk => status == 'healthy' || status == 'warning';
}

class AccountEntry {
  const AccountEntry({required this.meta, this.sizeKb, this.health});

  final AccountMeta meta;
  final int? sizeKb;
  final AccountHealth? health;
}

/// 切换阶段（UI 进度条用）。
enum SwitchPhase {
  preparing('准备'),
  normalizing('标准化资料'),
  terminating('结束进程'),
  writing('写入登录态'),
  clearingCache('清理缓存'),
  launching('启动 ZCode'),
  done('完成');

  const SwitchPhase(this.label);
  final String label;
}

class SwitchResult {
  const SwitchResult({
    required this.snapshotId,
    required this.mode,
    required this.restarted,
    required this.wasRunning,
    this.message,
  });

  final String snapshotId;
  final String mode; // guided-quit | auto-restart | cold-start
  final bool restarted;
  final bool wasRunning;
  final String? message;
}

class PlanTierInfo {
  const PlanTierInfo({
    required this.tier,
    required this.label,
    required this.isPlan,
    required this.isPlus,
    required this.isPro,
    this.billingCycle,
  });

  final String tier; // plus | pro | free | 其他
  final String label;
  final bool isPlan;
  final bool isPlus;
  final bool isPro;
  final String? billingCycle;
}

class QuotaItem {
  const QuotaItem({
    required this.label,
    required this.used,
    required this.quota,
    required this.percent,
    required this.status,
    this.kind = 'quota',
    this.resetAt,
    this.raw,
  });

  final String label;
  final double used;
  final double quota;
  final double percent;
  final String status; // healthy | low | warning | exhausted
  final String kind; // free | quota | detail | used
  final int? resetAt; // 窗口重置时间（毫秒时间戳）
  final Object? raw;
}

class QuotaOverview {
  const QuotaOverview({
    this.provider = 'unknown',
    this.status = 'noop',
    this.error,
    this.plan,
    this.items = const [],
    this.balance,
    this.billingCycle,
    this.credit,
    this.topUp,
    this.cycleStart,
    this.cycleEnd,
    this.raw,
  });

  final String provider;
  final String status; // ok | noop | error
  final String? error;
  final PlanTierInfo? plan;
  final List<QuotaItem> items;
  final double? balance;
  final String? billingCycle;
  final double? credit;
  final double? topUp;
  final String? cycleStart;
  final String? cycleEnd;
  final Object? raw;

  bool get isOk => status == 'ok';
  bool get isEmpty => status == 'noop';
  bool get hasPlan => plan != null;
}

class RuntimeProcess {
  const RuntimeProcess({required this.pid, this.name, this.bundleId, this.path});

  final int pid;
  final String? name;
  final String? bundleId;
  final String? path;
}

class InstanceAccount {
  const InstanceAccount({
    this.id,
    this.label,
    this.email,
    this.name,
    this.provider,
  });

  final String? id;
  final String? label;
  final String? email;
  final String? name;
  final String? provider;

  String get displayLabel => (email?.isNotEmpty == true)
      ? email!
      : (label?.isNotEmpty == true)
          ? label!
          : (name?.isNotEmpty == true)
              ? name!
              : '未识别账号';
}

class RuntimeInstance {
  const RuntimeInstance({
    required this.id,
    required this.name,
    this.pid,
    this.bindAccountId,
    this.running = false,
    this.managed = false,
    this.account,
    this.exePath,
  });

  final String id;
  final String name;
  final int? pid;
  final String? bindAccountId;
  final bool running;
  final bool managed;
  final InstanceAccount? account;

  /// 可执行文件路径（外部进程用于辨识来源，如 /Applications/ZCode.app/...）。
  final String? exePath;
}

/// OAuth 登录阶段（进展提示用）。
enum LoginPhase {
  preparing('准备回调'),
  browserOpen('打开浏览器'),
  waiting('等待登录'),
  exchanging('换取令牌'),
  saving('保存账号'),
  done('完成');

  const LoginPhase(this.label);
  final String label;
}

class LoginResult {
  const LoginResult({
    required this.provider,
    this.account,
    this.created = false,
    this.skipped = false,
    this.email,
    this.name,
  });

  final String provider; // zai | bigmodel
  final AccountMeta? account;
  final bool created;
  final bool skipped;
  final String? email;
  final String? name;
}

typedef LoginPhaseHandler = void Function(LoginPhase phase, String message);
