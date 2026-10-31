import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';

class AgentLogoWidget extends StatelessWidget {
  final AgentType agentType;
  final double size;
  final Color? customColor;
  final String monogram;

  const AgentLogoWidget({
    super.key,
    required this.agentType,
    this.size = 34.0,
    this.customColor,
    this.monogram = '',
  });

  @override
  Widget build(BuildContext context) {
    final brandColor = customColor ?? agentType.brandColor;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppConstants.bgWell,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: brandColor.withValues(alpha: 0.35),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: brandColor.withValues(alpha: 0.12),
            blurRadius: 8,
            spreadRadius: 0.5,
          ),
        ],
      ),
      child: Center(
        child: agentType == AgentType.custom
            ? Text(
                monogram,
                style: TextStyle(
                  color: brandColor,
                  fontWeight: FontWeight.w800,
                  fontSize: size * 0.36,
                ),
              )
            : CustomPaint(
          size: Size(size * 0.62, size * 0.62),
          painter: _AgentLogoPainter(agentType: agentType),
        ),
      ),
    );
  }
}

class _AgentLogoPainter extends CustomPainter {
  final AgentType agentType;

  const _AgentLogoPainter({required this.agentType});

  @override
  void paint(Canvas canvas, Size size) {
    switch (agentType) {
      case AgentType.codex:
        _paintCodexLogo(canvas, size);
        break;
      case AgentType.antigravity:
        _paintAntigravityLogo(canvas, size);
        break;
      case AgentType.claude:
        _paintClaudeLogo(canvas, size);
        break;
      case AgentType.custom:
        break; // rendered as a text monogram in AgentLogoWidget
    }
  }

  /// OpenAI Codex: Hexagonal interlocking spiral knot in emerald/teal (#10A37F / #37B99C).
  void _paintCodexLogo(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.44;

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.105
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF37B99C),
          Color(0xFF10A37F),
        ],
      ).createShader(Offset.zero & size);

    // Draw 6 interlocking rotational segments forming the iconic OpenAI / Codex knot
    for (int i = 0; i < 6; i++) {
      final angle = (i * math.pi / 3) - math.pi / 6;
      final petalCenter = Offset(
        center.dx + math.cos(angle) * (radius * 0.36),
        center.dy + math.sin(angle) * (radius * 0.36),
      );
      final rect = Rect.fromCircle(center: petalCenter, radius: radius * 0.56);
      canvas.drawArc(
        rect,
        angle - 0.55,
        math.pi * 0.72,
        false,
        strokePaint,
      );
    }

    // Crisp central hexagonal core outline
    final hexPath = Path();
    final innerR = radius * 0.30;
    for (int i = 0; i < 6; i++) {
      final a = (i * math.pi / 3);
      final pt = Offset(
        center.dx + math.cos(a) * innerR,
        center.dy + math.sin(a) * innerR,
      );
      if (i == 0) {
        hexPath.moveTo(pt.dx, pt.dy);
      } else {
        hexPath.lineTo(pt.dx, pt.dy);
      }
    }
    hexPath.close();
    canvas.drawPath(
      hexPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.06
        ..color = const Color(0xFF6EE7B7).withValues(alpha: 0.7),
    );
  }

  /// Google Antigravity: Four-point Gemini sparkle + orbital ring in cool periwinkle (#85A9FF).
  void _paintAntigravityLogo(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.48;

    // Subtle tilted orbital ring representing Antigravity
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-math.pi / 5);
    final orbitRect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width * 0.96,
      height: size.height * 0.44,
    );
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..color = const Color(0xFF85A9FF).withValues(alpha: 0.48);
    canvas.drawOval(orbitRect, orbitPaint);
    canvas.restore();

    // Four-point concave Gemini / Antigravity star
    final starPath = Path()
      ..moveTo(cx, cy - r)
      ..quadraticBezierTo(cx, cy, cx + r, cy)
      ..quadraticBezierTo(cx, cy, cx, cy + r)
      ..quadraticBezierTo(cx, cy, cx - r, cy)
      ..quadraticBezierTo(cx, cy, cx, cy - r)
      ..close();

    final starPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFA5B4FC),
          Color(0xFF85A9FF),
          Color(0xFF38BDF8),
        ],
      ).createShader(Offset.zero & size);

    canvas.drawPath(starPath, starPaint);
  }

  /// Claude Code: Iconic Anthropic/Claude warm terracotta starburst spark (#D97757 / #CC8D6B).
  void _paintClaudeLogo(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width * 0.46;
    final innerR = size.width * 0.11;

    final rayPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.105
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFFE59876),
          Color(0xFFD97757),
          Color(0xFFCC8D6B),
        ],
      ).createShader(Offset.zero & size);

    // 10-ray asymmetric organic starburst characteristic of Claude's spark emblem
    const rayCount = 10;
    for (int i = 0; i < rayCount; i++) {
      final angle = (i * 2 * math.pi / rayCount) - math.pi / 2;
      final rayScale = (i % 2 == 0) ? 1.0 : 0.82;
      final start = Offset(
        center.dx + math.cos(angle) * innerR,
        center.dy + math.sin(angle) * innerR,
      );
      final end = Offset(
        center.dx + math.cos(angle) * (outerR * rayScale),
        center.dy + math.sin(angle) * (outerR * rayScale),
      );
      canvas.drawLine(start, end, rayPaint);
    }

    canvas.drawCircle(
      center,
      innerR * 1.15,
      Paint()..color = const Color(0xFFD97757),
    );
  }

  @override
  bool shouldRepaint(covariant _AgentLogoPainter oldDelegate) {
    return oldDelegate.agentType != agentType;
  }
}
