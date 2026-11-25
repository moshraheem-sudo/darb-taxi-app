import 'package:flutter/material.dart';

/// Unified brand color tokens for Darb Taxi (Passenger & Captain).
class DarbColors {
  const DarbColors._();

  static const Color green = Color(0xFF087F65);
  static const Color blue = Color(0xFF0038FF);
  static const Color ink = Color(0xFF142421);
  static const Color canvas = Color(0xFFF4F6F5);
  static const Color orange = Color(0xFFE56A2B);

  static const Color darkBg = Color(0xFF101A18);
  static const Color darkSurface = Color(0xFF182522);
  static const Color darkSurfaceAlt = Color(0xFF22312E);
  static const Color darkBorder = Color(0xFF30413D);
  static const Color lightBorder = Color(0xFFE6EAE8);
}

/// Centralized Material 3 light & dark themes for Darb Taxi.
class DarbTheme {
  const DarbTheme._();

  static ThemeData build(bool dark) => ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: DarbColors.green,
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? const Color(0xFF17211F) : const Color(0xFFF8FAF9),
      surfaceContainerHighest: dark
          ? DarbColors.darkSurfaceAlt
          : const Color(0xFFEFF3F1),
    ),
    scaffoldBackgroundColor: dark ? DarbColors.darkBg : DarbColors.canvas,
    cardColor: dark ? DarbColors.darkSurface : Colors.white,
    canvasColor: dark ? DarbColors.darkBg : DarbColors.canvas,
    dividerColor: dark ? DarbColors.darkBorder : DarbColors.lightBorder,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? DarbColors.darkBg : Colors.white,
      foregroundColor: dark ? Colors.white : DarbColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: dark ? DarbColors.darkSurface : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: dark ? DarbColors.darkBorder : DarbColors.lightBorder,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? DarbColors.darkSurfaceAlt : const Color(0xFFF7F8FA),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: dark ? DarbColors.darkBorder : const Color(0xFFE2E5E4),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: dark ? DarbColors.darkBorder : const Color(0xFFE2E5E4),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? DarbColors.darkSurface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    fontFamily: 'Arial',
  );
}
