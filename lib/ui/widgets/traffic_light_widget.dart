import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';

class TrafficLightWidget extends StatelessWidget {
  final TrafficLightState activeState;
  final VoidCallback? onTap;
  final bool vertical;
  final double lampSize;

  const TrafficLightWidget({
    super.key,
    required this.activeState,
    this.onTap,
    this.vertical = false,
    this.lampSize = 11.5,
  });

  static const List<TrafficLightState> _chambersOrder = [
    TrafficLightState.outOfUsage, // 1. RED (#FF2A2A)
    TrafficLightState.needsInput, // 2. YELLOW (#FFB800)
    TrafficLightState.working,    // 3. GREEN (#00E676)
    TrafficLightState.idle,       // 4. WHITE (#F8FAFC)
  ];

  String _tooltipForState(TrafficLightState state) {
    switch (state) {
      case TrafficLightState.outOfUsage:
        return 'ROT (Kammer 1): Limit erschöpft (0% übrig) oder Rate-Limit / API-Fehler';
      case TrafficLightState.needsInput:
        return 'GELB (Kammer 2): Wartet auf Benutzer-Eingabe oder Tool-Freigabe';
      case TrafficLightState.working:
        return 'GRÜN (Kammer 3): Agent arbeitet aktiv (führt Tools aus / denkt nach)';
      case TrafficLightState.idle:
        return 'WEISS (Kammer 4): Bereit / Idle (Aufgabe abgeschlossen)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final lamps = _chambersOrder.map((chamberState) {
      final isActive = chamberState == activeState;
      return _ChamberLamp(
        color: chamberState.color,
        isActive: isActive,
        size: lampSize,
      );
    }).toList();

    return Tooltip(
      message: _tooltipForState(activeState),
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5.5),
            decoration: BoxDecoration(
              color: AppConstants.bgWell, // #07090D housing
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppConstants.borderSubtle, // #1E293B fine border
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: vertical
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < lamps.length; i++) ...[
                        if (i > 0) const SizedBox(height: 5),
                        lamps[i],
                      ],
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < lamps.length; i++) ...[
                        if (i > 0) const SizedBox(width: 5.5),
                        lamps[i],
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ChamberLamp extends StatelessWidget {
  final Color color;
  final bool isActive;
  final double size;

  const _ChamberLamp({
    required this.color,
    required this.isActive,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive
            ? color.withValues(alpha: 1.0)
            : color.withValues(alpha: 0.12),
        border: Border.all(
          color: isActive
              ? Colors.white.withValues(alpha: 0.55)
              : Colors.white.withValues(alpha: 0.06),
          width: 0.8,
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.85),
                  blurRadius: 6,
                  spreadRadius: 1.2,
                ),
                BoxShadow(
                  color: color.withValues(alpha: 0.42),
                  blurRadius: 14,
                  spreadRadius: 2.5,
                ),
              ]
            : const [],
      ),
      child: isActive
          ? Align(
              alignment: const Alignment(-0.35, -0.35),
              child: Container(
                width: size * 0.30,
                height: size * 0.30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.72),
                ),
              ),
            )
          : null,
    );
  }
}
