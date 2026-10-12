import 'package:flutter/material.dart';

/// Палитра по фирменному стилю nox.drive: матовый чёрный, графит, холодный металл.
/// Неоновыми остаются только статусные цвета (ADB, успех, ошибка).
class NoxColors {
  static const bg = Color(0xFF0A0A0B);
  static const panel = Color(0xFF141416);
  static const panelHi = Color(0xFF1B1B1E);
  static const border = Color(0xFF2A2B2F);
  static const metalLight = Color(0xFFD5D8DD);
  static const metalMid = Color(0xFF8B9097);
  static const metalDark = Color(0xFF55595F);
  static const ok = Color(0xFF2EE66B);
  static const bad = Color(0xFFFF4D5A);
  static const warn = Color(0xFFFFB74D);

  /// Металлический градиент для заголовков и акцентных линий.
  static const metal = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [metalLight, metalMid, Color(0xFFB5B9BF)],
  );
}

ThemeData buildDarkTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: NoxColors.metalMid,
        brightness: Brightness.dark,
      ).copyWith(
        surface: NoxColors.panel,
        primary: NoxColors.metalLight,
        onPrimary: NoxColors.bg,
        primaryContainer: NoxColors.panelHi,
        onPrimaryContainer: NoxColors.metalLight,
        outline: NoxColors.border,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: NoxColors.bg,
    colorScheme: scheme,
    dividerColor: NoxColors.border,
    cardTheme: CardThemeData(
      color: NoxColors.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: NoxColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NoxColors.panelHi,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NoxColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NoxColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NoxColors.metalLight),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: NoxColors.panelHi,
      selectedColor: NoxColors.metalDark,
      side: const BorderSide(color: NoxColors.border),
      labelStyle: const TextStyle(color: NoxColors.metalLight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NoxColors.metalLight,
        foregroundColor: NoxColors.bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: NoxColors.metalLight,
      linearTrackColor: NoxColors.panelHi,
    ),
  );
}
