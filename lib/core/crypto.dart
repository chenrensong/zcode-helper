import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// ZCode `enc:v1` AES-256-GCM 加解密（与 Electron 工具字节级兼容）。
///
/// 格式：`enc:v1:<nonce_base64url>.<authTag_base64url>.<cipherText_base64url>`
/// 密钥：`sha256(secret)`，secret 优先取 `ZCODE_CREDENTIAL_SECRET`，否则
/// `zcode-credential-fallback:<platform>:<homedir>:<username>`。
const String encPrefix = 'enc:v1:';

String? _env(String name) {
  try {
    return Platform.environment[name];
  } catch (_) {
    return null;
  }
}

/// 与 Node `os.platform()` 对齐：macos -> darwin、windows -> win32、linux -> linux。
String defaultPlatformName() {
  switch (Platform.operatingSystem) {
    case 'macos':
      return 'darwin';
    case 'windows':
      return 'win32';
    default:
      return Platform.operatingSystem;
  }
}

/// 运行时密钥覆盖：沙箱内 $HOME 是容器路径，而 ZCode 凭据用**真实** home 派生密钥，
/// 因此从原生层取到真实身份的 fallback secret 后覆盖此值（env 仍优先）。
String? _credentialSecretOverride;

void setDefaultCredentialSecretOverride(String? secret) {
  _credentialSecretOverride = secret;
}

String defaultCredentialSecret({
  String? platform,
  String? home,
  String? username,
}) {
  final envSecret = _env('ZCODE_CREDENTIAL_SECRET');
  if (envSecret != null && envSecret.isNotEmpty) return envSecret;
  final override = _credentialSecretOverride;
  if (override != null && override.isNotEmpty) return override;
  final p = platform ?? defaultPlatformName();
  final h = home ?? Platform.environment['HOME'] ?? '';
  var u = username ?? '';
  if (u.isEmpty) {
    try {
      u = Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'unknown';
    } catch (_) {
      u = 'unknown';
    }
  }
  return 'zcode-credential-fallback:$p:$h:$u';
}

Future<List<int>> deriveKey(String secret) async {
  final hash = await Sha256().hash(utf8.encode(secret));
  return hash.bytes;
}

bool isEncrypted(Object? value) {
  return value is String && value.startsWith(encPrefix);
}

String _b64urlEncode(List<int> bytes) => base64Url.encode(bytes);

List<int> _b64urlDecode(String s) => base64Url.decode(base64Url.normalize(s));

/// 加密明文，返回 `enc:v1:` 密文（与原工具 / 客户端格式一致）。
Future<String> encrypt(String plainText, {String? secret}) async {
  final key = await deriveKey(secret ?? defaultCredentialSecret());
  final algorithm = AesGcm.with256bits();
  final nonce = algorithm.newNonce();
  final box = await algorithm.encrypt(
    utf8.encode(plainText),
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  final parts = [
    _b64urlEncode(box.nonce),
    _b64urlEncode(box.mac.bytes),
    _b64urlEncode(box.cipherText),
  ];
  return '$encPrefix${parts.join('.')}';
}

/// 解密 `enc:v1:` 密文；非密文原样返回；失败抛 [FormatException]。
Future<String> decrypt(String value, {String? secret}) async {
  if (!isEncrypted(value)) return value;
  final body = value.substring(encPrefix.length);
  final parts = body.split('.');
  if (parts.length != 3) throw const FormatException('enc:v1 格式不正确');
  final key = await deriveKey(secret ?? defaultCredentialSecret());
  final algorithm = AesGcm.with256bits();
  final box = SecretBox(
    _b64urlDecode(parts[2]),
    nonce: _b64urlDecode(parts[0]),
    mac: Mac(_b64urlDecode(parts[1])),
  );
  try {
    final clear = await algorithm.decrypt(box, secretKey: SecretKey(key));
    return utf8.decode(clear);
  } catch (e) {
    throw FormatException('解密失败: $e');
  }
}

/// 安全解密：密文 -> 若可解则返回明文，否则 null。
Future<String?> safeDecrypt(Object? value, {String? secret}) async {
  if (value == null) return null;
  try {
    final plain = isEncrypted(value) ? await decrypt(value as String, secret: secret) : value as String;
    return plain;
  } catch (_) {
    return null;
  }
}

/// 解密并解析 JSON；失败返回 null。
Future<Object?> decryptJson(Object? value, {String? secret}) async {
  final plain = await safeDecrypt(value, secret: secret);
  if (plain == null) return null;
  try {
    return jsonDecode(plain);
  } catch (_) {
    return null;
  }
}

/// 短哈希（仅用于弱指纹去重，非安全用途）。
String simpleHash(String s) {
  var h = 5381;
  for (final code in s.codeUnits) {
    h = ((h * 33) ^ code) & 0xFFFFFFFF;
  }
  return h.toRadixString(16);
}
