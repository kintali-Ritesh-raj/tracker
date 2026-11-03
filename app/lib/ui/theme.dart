import 'package:flutter/material.dart';

import '../core/models.dart';

/// Design tokens taken from the SLG FieldTrack reference screens.
abstract final class AppColors {
  static const orange = Color(0xFFF97316);
  static const orangeDeep = Color(0xFFEA580C);
  static const orangeSoft = Color(0xFFFFEDD5);
  static const orangeTint = Color(0xFFFFF4EA);
  static const cream = Color(0xFFFFF9F4);
  static const creamDeep = Color(0xFFFDF1E6);
  static const surface = Colors.white;
  static const ink = Color(0xFF1C1917);
  static const inkSoft = Color(0xFF44403C);
  static const muted = Color(0xFF78716C);
  static const hairline = Color(0xFFF1E7DD);

  static const onSite = Color(0xFF16A34A);
  static const onSiteSoft = Color(0xFFDCFCE7);
  static const inTransit = Color(0xFFF59E0B);
  static const inTransitSoft = Color(0xFFFEF3C7);
  static const offline = Color(0xFFEF4444);
  static const offlineSoft = Color(0xFFFEE2E2);

  static Color status(EmployeeStatus s) => switch (s) {
        EmployeeStatus.onSite => onSite,
        EmployeeStatus.inTransit => inTransit,
        EmployeeStatus.offline => offline,
      };

  static Color statusSoft(EmployeeStatus s) => switch (s) {
        EmployeeStatus.onSite => onSiteSoft,
        EmployeeStatus.inTransit => inTransitSoft,
        EmployeeStatus.offline => offlineSoft,
      };

  static Color request(RequestStatus s) => switch (s) {
        RequestStatus.pending => inTransit,
        RequestStatus.approved => onSite,
        RequestStatus.declined => offline,
        RequestStatus.unavailable => muted,
      };

  static Color hex(String? value, {Color fallback = orange}) {
    if (value == null || value.length != 7) return fallback;
    return Color(int.parse('FF${value.substring(1)}', radix: 16));
  }
}

abstract final class AppRadius {
  static const card = 20.0;
  static const tile = 18.0;
  static const pill = 999.0;
}

abstract final class AppShadow {
  static const soft = [
    BoxShadow(color: Color(0x14C2410C), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x08000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const button = [
    BoxShadow(color: Color(0x40F97316), blurRadius: 20, offset: Offset(0, 8)),
  ];
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.orange,
    primary: AppColors.orange,
    surface: AppColors.cream,
    brightness: Brightness.light,
  );
  const text = TextTheme(
    headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.6),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.4),
    titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.ink, letterSpacing: -0.2),
    titleSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.ink),
    bodyLarge: TextStyle(fontSize: 16, color: AppColors.inkSoft, height: 1.4),
    bodyMedium: TextStyle(fontSize: 14, color: AppColors.inkSoft, height: 1.4),
    bodySmall: TextStyle(fontSize: 12.5, color: AppColors.muted, height: 1.35),
    labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0),
    labelMedium: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: AppColors.inkSoft),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.cream,
    textTheme: text,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      foregroundColor: AppColors.ink,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      labelStyle: const TextStyle(color: AppColors.muted),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.hairline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.hairline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.orange, width: 1.5)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.orange : const Color(0xFFE7E5E4),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    }),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
  );
}
