import 'package:flutter/material.dart';

/// ZCode 品牌强调色（明暗两套主题通用）。
///
/// 来源对照（zcode.z.ai 全站 CSS 变量）：
/// - --brand / --ring: sky-500 = #0ea5e9
/// - 命令节点 amber #f99c00、技能节点 #8d54ff
abstract final class ZcodePalette {
  // 品牌色（zcode.z.ai --brand，sky-500）
  static const Color brand = Color(0xFF0EA5E9);
  static const Color brandSoft = Color(0x330EA5E9); // 20%
  static const Color commandNode = Color(0xFFF99C00); // amber
  static const Color skillNode = Color(0xFF8D54FF); // purple

  // 渠道品牌
  static const Color zai = Color(0xFF0EA5E9); // Z.ai / zcode.z.ai 同源 sky
  static const Color bigmodel = Color(0xFF2554FF); // bigmodel.cn 品牌蓝

  // 语义色（对齐站点终端绿 / amber / destructive）
  static const Color success = Color(0xFF28C840);
  static const Color warning = Color(0xFFF99C00);
  static const Color error = Color(0xFFF0716D);

  /// provider 标识是否为 BigModel 渠道（其余按 Z.ai 处理）。
  static bool isBigModel(String? provider) =>
      (provider ?? '').toLowerCase().contains('bigmodel');

  /// 渠道 → 品牌色。
  static Color providerColor(String? provider) =>
      isBigModel(provider) ? bigmodel : zai;
}

/// 明暗两套表面 / 文字令牌。
///
/// 深色直接对齐 zcode.z.ai（Tailwind neutral 深灰阶 + #fafafa 10% 描边）；
/// 浅色按同一 neutral 体系推导（neutral-50 底 / 纯白卡片 / 黑 8% 描边），
/// 品牌色不变，保证两套主题下视觉同源。
class ZcodeTokens {
  const ZcodeTokens({
    required this.brightness,
    required this.background,
    required this.card,
    required this.cardSelected,
    required this.border,
    required this.borderHover,
    required this.surface,
    required this.surfaceHover,
    required this.foreground,
    required this.mutedForeground,
    required this.subtleForeground,
    required this.successMuted,
    required this.errorMuted,
  });

  final Brightness brightness;

  // 底色 / 表面
  final Color background; // 页面背景
  final Color card; // 卡片
  final Color cardSelected; // 选中态 / 浮层

  // 描边 / 叠层
  final Color border; // 常规描边（前景色 8-10% 透明）
  final Color borderHover;
  final Color surface; // 行内浅叠层
  final Color surfaceHover; // 行内叠层 / 输入框填充

  // 文字
  final Color foreground; // 主文字
  final Color mutedForeground; // 次要文字（约 60% 强度）
  final Color subtleForeground; // 辅助文字（约 45% 强度）

  // 语义弱化文字（长错误说明等）
  final Color successMuted;
  final Color errorMuted;

  static const ZcodeTokens dark = ZcodeTokens(
    brightness: Brightness.dark,
    background: Color(0xFF161616), // neutral-900
    card: Color(0xFF262626), // neutral-800
    cardSelected: Color(0xFF404040), // neutral-700
    border: Color(0x1AFAFAFA), // white 10%
    borderHover: Color(0x4DFAFAFA), // white 30%
    surface: Color(0x0DFFFFFF), // white 5%
    surfaceHover: Color(0x1AFFFFFF), // white 10%
    foreground: Color(0xFFFAFAFA), // neutral-50
    mutedForeground: Color(0xFFA3A3A3), // neutral-400
    subtleForeground: Color(0xFF8C8C8C),
    successMuted: Color(0xFF7EC98F),
    errorMuted: Color(0xFFC99493),
  );

  static const ZcodeTokens light = ZcodeTokens(
    brightness: Brightness.light,
    background: Color(0xFFFAFAFA), // neutral-50
    card: Color(0xFFFFFFFF),
    cardSelected: Color(0xFFE5E5E5), // neutral-200
    border: Color(0x14000000), // black 8%
    borderHover: Color(0x42000000), // black 26%
    surface: Color(0x0A000000), // black 4%
    surfaceHover: Color(0x14000000), // black 8%
    foreground: Color(0xFF171717), // neutral-900
    mutedForeground: Color(0xFF525252), // neutral-600
    subtleForeground: Color(0xFF737373), // neutral-500
    successMuted: Color(0xFF3D8B4F),
    errorMuted: Color(0xFFA3524F),
  );

  /// 从当前 BuildContext 的主题亮度取令牌。
  static ZcodeTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// ZCode 品牌标：直接使用 zcode.z.ai 官方 favicon
/// （经 Google s2 favicons 服务取 128px 版本，白色外圈 + 深底 + 白色 Z）。
class ZcodeMark extends StatelessWidget {
  const ZcodeMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/brands/zcode.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// 渠道品牌标：Z.ai / BigModel 均使用官方 favicon 资源图片
/// （Google s2 favicons 128px，BigModel 为蓝渐变底 + 智谱几何标）。
class ProviderMark extends StatelessWidget {
  const ProviderMark({super.key, this.size = 36, required this.provider});

  final double size;
  final String? provider;

  @override
  Widget build(BuildContext context) {
    final isBig = ZcodePalette.isBigModel(provider);
    return Image.asset(
      isBig ? 'assets/brands/bigmodel.png' : 'assets/brands/zai.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
    );
  }
}
