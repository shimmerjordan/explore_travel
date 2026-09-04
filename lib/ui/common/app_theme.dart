/// 全局主题（像素语言 v2）。从 main.dart 抽出，好让测试能直接构建两套主题并
/// 对其做对比度断言——这是 PRODUCT.md 的 WCAG AA 目标唯一可自动化的检查点。
library;

import 'package:flutter/material.dart';

// ── Pixel design language, v2 ─────────────────────────────────────────
// The FOW metaphor is a game mechanic; the whole app speaks pixel now:
//  · 缝合像素字体 as the GLOBAL text face (body, labels, buttons, tips) —
//    per explicit user preference; glyph fallback handles rare chars.
//  · Friendly-but-crisp radii (buttons keep a visible curve; panels stay
//    chunky). Stepped pixel corners remain reserved for hero panels.
//  · Menus/dropdowns get flat tonal surfaces with a 1.5px outline —
//    "inventory panel" read instead of floating Material shadows.
//  · Light scheme is the "轻快" mode: vibrant seed, airy tinted surfaces.
ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // Pixel-game palette pairing: teal carries identity (primary), warm
  // AMBER is the companion accent, coral the highlight. A single-seed
  // tonalSpot scheme rendered everything into one navy-grey family
  // ("全是暗色系没有搭配"); overriding the secondary/tertiary role families
  // recolours every tonal button, selected segment, checked chip and
  // badge app-wide — M3 semantics intact, retro warm-vs-cool contrast on.
  final seeded = ColorScheme.fromSeed(
    seedColor: const Color(0xFF26A69A),
    brightness: brightness,
    // Light mode carries the "轻快" personality: punchier chroma.
    dynamicSchemeVariant:
        dark ? DynamicSchemeVariant.tonalSpot : DynamicSchemeVariant.vibrant,
  );
  final scheme = dark
      ? seeded.copyWith(
          // Amber "coin/torch" accent family.
          secondary: const Color(0xFFF2B457),
          onSecondary: const Color(0xFF3F2B00),
          secondaryContainer: const Color(0xFF5C4014),
          onSecondaryContainer: const Color(0xFFFFDFAC),
          // Coral "heart/flag" highlight family.
          tertiary: const Color(0xFFFF8A70),
          onTertiary: const Color(0xFF4A1505),
          tertiaryContainer: const Color(0xFF6E3021),
          onTertiaryContainer: const Color(0xFFFFDBCF),
          // Surfaces get a subtle teal cast instead of flat navy-grey.
          surfaceContainerHighest: const Color(0xFF2A3B46),
          surfaceContainerHigh: const Color(0xFF24343F),
        )
      : seeded.copyWith(
          secondary: const Color(0xFF875200),
          onSecondary: Colors.white,
          secondaryContainer: const Color(0xFFFFE0B0),
          onSecondaryContainer: const Color(0xFF4A2D00),
          tertiary: const Color(0xFFB13B22),
          onTertiary: Colors.white,
          tertiaryContainer: const Color(0xFFFFDBCF),
          onTertiaryContainer: const Color(0xFF551F0E),
        );
  RoundedRectangleBorder box(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
  final outline = scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.9);

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // Global pixel face. 14sp body in a 12px-grid font stays legible;
    // missing glyphs fall back to the system face automatically.
    fontFamily: 'PixelZh',
    // 像素字体是 12px 网格的：**大字号只有落在 12 的整数倍上才不发糊**
    // （24 / 36 / 48）。所以 display 与 headline 两族显式钉在网格上；
    // title / body / label 保持 M3 默认（16 / 14 / 12 / 11），它们本来就在
    // 可读区间，而且动它们等于把全应用的列表、按钮、AppBar 一起改版。
    //
    // 这两档的数值与 `PixelText.display` / `PixelText.headline` 逐字段一致，
    // 页面从那两个常量迁到 `textTheme` 时是视觉上的 no-op。
    textTheme: const TextTheme(
      displaySmall:
          TextStyle(fontSize: 36, height: 1.15, letterSpacing: 0),
      headlineSmall:
          TextStyle(fontSize: 24, height: 1.2, letterSpacing: 0),
    ).apply(fontFamily: 'PixelZh'),
    // Dark stays moody but lifts off pure-black; light is an airy
    // teal-tinted paper so the map and tonal panels breathe.
    scaffoldBackgroundColor:
        dark ? const Color(0xFF14212C) : const Color(0xFFF3FAF8),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF1B2D38) : null,
      shape: box(8),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: dark ? 0 : 1,
      backgroundColor:
          dark ? const Color(0xFF14212C) : const Color(0xFFF3FAF8),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      shape: box(12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: box(8),
    ),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8))),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    chipTheme: ChipThemeData(shape: box(6), side: BorderSide.none),
    // Buttons: crisp but friendly — a clear curve, not a stadium and
    // not a brick.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: box(10)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: box(10)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: box(10),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.55)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: box(10)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(box(10))),
    ),
    dialogTheme: DialogThemeData(shape: box(14)),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    // Menus / dropdowns as flat "inventory panels": tonal surface, real
    // border, minimal shadow — a deliberate pixel-RPG affordance.
    popupMenuTheme: PopupMenuThemeData(
      elevation: 2,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: outline, width: 1.5),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(2),
        backgroundColor: WidgetStatePropertyAll(
            scheme.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: outline, width: 1.5),
        )),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        elevation: const WidgetStatePropertyAll(2),
        backgroundColor: WidgetStatePropertyAll(
            scheme.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: outline, width: 1.5),
        )),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
  return base;
}

/// 明暗两套主题各构建一次（ThemeData 不便宜，MaterialApp 每帧都读）。
final ThemeData lightAppTheme = buildAppTheme(Brightness.light);
final ThemeData darkAppTheme = buildAppTheme(Brightness.dark);
