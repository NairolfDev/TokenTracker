import 'package:flutter/material.dart';
import '../../models/app_constants.dart';

class AmpelTheme {
  AmpelTheme._();

  static const Color bgPrimary = AppConstants.bgPrimary;
  static const Color bgCard = AppConstants.bgCard;
  static const Color bgHover = AppConstants.bgHousing;
  static const Color borderSubtle = AppConstants.borderSubtle;
  static const Color bgWell = AppConstants.bgWell;

  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  static const List<FontFeature> tabularFigures = [
    FontFeature.tabularFigures(),
  ];

  static ThemeData get darkTheme {
    const baseScheme = ColorScheme.dark(
      surface: bgPrimary,
      primary: Color(0xFF38BDF8),
      secondary: AppConstants.accentAntigravity,
      error: AppConstants.ampelRed,
      onSurface: textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: bgPrimary,
      colorScheme: baseScheme,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const [
        'Inter',
        'Roboto',
        'SF Pro Text',
        'Ubuntu',
        'sans-serif',
      ],
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderSubtle, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        textStyle: const TextStyle(
          color: textPrimary,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          fontFeatures: tabularFigures,
        ),
        waitDuration: const Duration(milliseconds: 280),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: borderSubtle, width: 1),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppConstants.ampelGreen;
          }
          return textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppConstants.ampelGreen.withValues(alpha: 0.25);
          }
          return bgWell;
        }),
      ),
    );
  }
}
