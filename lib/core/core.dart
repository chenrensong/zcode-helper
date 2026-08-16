/// 通用小工具。
library;

/// 返回第一个非空字符串；全部为空返回 null。
String? firstText(List<Object?> values) {
  for (final v in values) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

int? toIntNumber(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.round();
  if (value is String && value.trim().isNotEmpty) {
    final n = int.tryParse(value.replaceAll(',', ''));
    if (n != null) return n;
    final d = double.tryParse(value.replaceAll(',', ''));
    if (d != null) return d.round();
  }
  return null;
}

double? toNum(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String && value.trim().isNotEmpty) {
    return double.tryParse(value.replaceAll(',', ''));
  }
  return null;
}

double clampNum(double v, double min, double max) => v < min ? min : (v > max ? max : v);

Map<String, dynamic> asMap(Object? value) =>
    (value is Map) ? Map<String, dynamic>.from(value) : <String, dynamic>{};
