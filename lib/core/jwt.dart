import 'dart:convert';

/// 解析 JWT payload（不验签，仅读取 base64url payload）。
Map<String, dynamic>? decodeJwt(String? jwt) {
  if (jwt == null || jwt.isEmpty) return null;
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = base64Url.decode(base64Url.normalize(parts[1]));
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  } catch (_) {
    return null;
  }
}
