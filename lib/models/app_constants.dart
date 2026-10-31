import 'package:flutter/material.dart';

class AppConstants {
  AppConstants._();

  static const String appTitle = 'Agent Lights';
  static const String appPackageName = 'agentlights';
  static const String githubOwner = 'NairolfDev';
  static const String githubRepo = 'AgentLights';
  static const int hookServerPort = 47832;
  static const String defaultLocalHost = '127.0.0.1';

  // Industrial Dark Mode & Glassmorphism Palette
  static const Color bgPrimary = Color(0xFF0B0E14);
  static const Color bgCard = Color(0xFF131722);
  static const Color bgHousing = Color(0xFF1A202C);
  static const Color borderSubtle = Color(0xFF1E293B);
  static const Color bgWell = Color(0xFF07090D);

  // 4-Chamber Traffic Light Colors
  static const Color ampelRed = Color(0xFFFF2A2A);
  static const Color ampelYellow = Color(0xFFFFB800);
  static const Color ampelGreen = Color(0xFF00E676);
  static const Color ampelWhite = Color(0xFFF8FAFC);

  // Neutral Ring Colors (Strictly separated from Traffic Light status!)
  static const Color ringNeutral = Color(0xFFCBD5E1);
  static const Color ringNeutralSecondary = Color(0xFF94A3B8);
  static const Color ringTrack = Color(0xFF1E293B);
  static const Color ringCritical = Color(0xFFFF2A2A);

  // Provider Brand Accents (Subtle header/badge accents)
  static const Color accentCodex = Color(0xFF37B99C);
  static const Color accentAntigravity = Color(0xFF85A9FF);
  static const Color accentClaude = Color(0xFFCC8D6B);

  // Compact HUD Dimensions
  static const double hudCollapsedWidth = 500.0;
  /// Windows at least this wide (large desktop window, tablet, web) use the large layout.
  static const double largeLayoutWidth = 720.0;
  static const double hudLargeWidth = 920.0;
  static const double hudLargeHeight = 680.0;
  static const double hudCollapsedHeight = 250.0;
  static const double hudExpandedHeight = 390.0;
}
