import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/app_constants.dart';
import '../../models/usage_window.dart';
import '../theme/ampel_theme.dart';

class DepletingUsageRing extends StatelessWidget {
  final UsageWindow window;
  final double size;
  final double strokeWidth;
  final bool showLabels;
  final bool compact;

  const DepletingUsageRing({
    super.key,
    required this.window,
    this.size = 36.0,
    this.strokeWidth = 3.4,
    this.showLabels = true,
    this.compact = true,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = !window.disabled && window.usedPercent != null;
    final remainingFraction = hasData ? window.remainingFraction : 0.0;
    final isCritical = hasData && remainingFraction <= 0.10;

    final tooltipLines = <String>[
      window.fullTitle,
      if (hasData)
        'Übrig: ${window.remainingPercentLabel} (Verbraucht: ${window.usedPercent!.round()}%)'
      else
        window.quotaLabel,
      if (window.customQuotaLabel != null && window.customQuotaLabel!.isNotEmpty)
        'Kontingent: ${window.customQuotaLabel}',
      resetLabel(window),
    ];

    final ringGraphic = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: DepletingUsageRingPainter(
              remainingFraction: remainingFraction,
              hasData: hasData,
              strokeWidth: strokeWidth,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(2.0),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                hasData ? '${window.remainingPercent!.round()}%' : '—',
                style: TextStyle(
                  fontSize: size * 0.28,
                  fontWeight: FontWeight.w700,
                  color: !hasData
                      ? AmpelTheme.textMuted
                      : (isCritical
                          ? AppConstants.ringCritical
                          : AmpelTheme.textPrimary),
                  fontFeatures: AmpelTheme.tabularFigures,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (!showLabels) {
      return Tooltip(
        message: tooltipLines.join('\n'),
        child: ringGraphic,
      );
    }

    return Tooltip(
      message: tooltipLines.join('\n'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ringGraphic,
          const SizedBox(height: 2.5),
          Text(
            window.shortLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 9.5 : 10.5,
              fontWeight: FontWeight.w600,
              color: isCritical
                  ? AppConstants.ringCritical
                  : AmpelTheme.textSecondary,
              fontFeatures: AmpelTheme.tabularFigures,
              height: 1.05,
            ),
          ),
          Text(
            window.resetCountdownLabel(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 8.5 : 9.5,
              fontWeight: FontWeight.w500,
              color: AmpelTheme.textMuted,
              fontFeatures: AmpelTheme.tabularFigures,
              height: 1.05,
            ),
          ),
        ],
      ),
    );
  }
}

class DepletingUsageRingPainter extends CustomPainter {
  final double remainingFraction;
  final bool hasData;
  final double strokeWidth;

  const DepletingUsageRingPainter({
    required this.remainingFraction,
    required this.hasData,
    this.strokeWidth = 3.4,
  });

  /// Strictly neutral cool silver-white (#CBD5E1) when > 10% remaining,
  /// immediately switching to Signal Red (#FF2A2A) when <= 10% remaining.
  Color get activeArcColor {
    if (!hasData) return AppConstants.ringNeutralSecondary.withValues(alpha: 0.3);
    if (remainingFraction <= 0.10) {
      return AppConstants.ringCritical; // #FF2A2A
    }
    return AppConstants.ringNeutral; // #CBD5E1
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 1. Background Track (#1E293B)
    final trackPaint = Paint()
      ..color = AppConstants.ringTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, trackPaint);

    if (!hasData) return;

    final clampedRemaining = remainingFraction.clamp(0.0, 1.0);
    if (clampedRemaining <= 0.0) {
      // At 0% remaining (100% used), draw a subtle red warning ring halo so the empty state is clearly critical
      final emptyCriticalPaint = Paint()
        ..color = AppConstants.ringCritical.withValues(alpha: 0.40)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.65;
      canvas.drawCircle(center, radius, emptyCriticalPaint);
      return;
    }

    final startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * clampedRemaining;
    final isCritical = clampedRemaining <= 0.10;

    // 2. Subtle red warning glow when <= 10% remaining
    if (isCritical) {
      final glowPaint = Paint()
        ..color = AppConstants.ringCritical.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 3.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
      canvas.drawArc(rect, startAngle, sweepAngle, false, glowPaint);
    }

    // 3. Depleting Foreground Arc (#CBD5E1 when > 10% remaining, #FF2A2A when <= 10% remaining)
    final activePaint = Paint()
      ..color = activeArcColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, startAngle, sweepAngle, false, activePaint);
  }

  @override
  bool shouldRepaint(covariant DepletingUsageRingPainter oldDelegate) {
    return oldDelegate.remainingFraction != remainingFraction ||
        oldDelegate.hasData != hasData ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
