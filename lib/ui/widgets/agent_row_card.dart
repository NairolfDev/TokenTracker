import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';
import '../theme/ampel_theme.dart';
import 'agent_logo_widget.dart';
import 'antigravity_limits_drawer.dart';
import 'depleting_usage_ring.dart';
import 'traffic_light_widget.dart';

class AgentRowCard extends StatefulWidget {
  final AgentStatusModel agent;
  final bool isAntigravityExpanded;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onCycleTrafficLight;

  /// Large layout (wide window / tablet / web): every window, bigger rings, drawer always open.
  final bool large;

  const AgentRowCard({
    super.key,
    required this.agent,
    this.isAntigravityExpanded = false,
    this.onToggleExpand,
    this.onCycleTrafficLight,
    this.large = false,
  });

  @override
  State<AgentRowCard> createState() => _AgentRowCardState();
}

class _AgentRowCardState extends State<AgentRowCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final isAntigravity = agent.agentType == AgentType.antigravity;
    final trafficState = agent.trafficLight;
    final primaryWindows =
        widget.large && !isAntigravity ? agent.windows : agent.primaryWindows;
    final totalSubLimitsCount = agent.allAntigravitySubLimits.isNotEmpty
        ? agent.allAntigravitySubLimits.length
        : agent.windows.length;

    Color borderColor = AppConstants.borderSubtle;
    if (trafficState == TrafficLightState.outOfUsage) {
      borderColor = AppConstants.ampelRed.withValues(alpha: 0.45);
    } else if (trafficState == TrafficLightState.needsInput) {
      borderColor = AppConstants.ampelYellow.withValues(alpha: 0.40);
    } else if (_isHovered) {
      borderColor = agent.accent.withValues(alpha: 0.45);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: isAntigravity ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: isAntigravity ? widget.onToggleExpand : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: widget.large ? 16 : 10,
            vertical: widget.large ? 12 : 7,
          ),
          decoration: BoxDecoration(
            color: _isHovered ? AppConstants.bgHousing : AppConstants.bgCard,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: borderColor, width: 1.0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ZONE 1 (Left): Crisp Vector AI Logo & Agent Title + Subtitle
                  Expanded(
                    child: Row(
                      children: [
                        AgentLogoWidget(
                          agentType: agent.agentType,
                          customColor: agent.customColor,
                          monogram: agent.monogram,
                          size: widget.large ? 48 : 34,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      agent.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: widget.large ? 16 : 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: AmpelTheme.textPrimary,
                                        letterSpacing: -0.1,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                  if (isAntigravity && !widget.large) ...[
                                    const SizedBox(width: 5),
                                    _ExpandPillButton(
                                      isExpanded: widget.isAntigravityExpanded,
                                      count: totalSubLimitsCount,
                                      onTap: widget.onToggleExpand,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2.5),
                              Row(
                                children: [
                                  Container(
                                    width: 5.5,
                                    height: 5.5,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: trafficState.color,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      agent.effectiveSubtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: widget.large ? 13 : 10.5,
                                        fontWeight: FontWeight.w500,
                                        color: trafficState ==
                                                TrafficLightState.outOfUsage
                                            ? AppConstants.ampelRed
                                            : (trafficState ==
                                                    TrafficLightState.needsInput
                                                ? AppConstants.ampelYellow
                                                : AmpelTheme.textSecondary),
                                        fontFeatures: AmpelTheme.tabularFigures,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 8),

                  // ZONE 2 (Middle): 4-Chamber Traffic Light
                  TrafficLightWidget(
                    activeState: trafficState,
                    onTap: widget.onCycleTrafficLight,
                  ),

                  const SizedBox(width: 10),

                  // ZONE 3 (Right): Depleting Usage Limit Rings
                  Flexible(
                    flex: 0,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < primaryWindows.length; i++) ...[
                          if (i > 0) const SizedBox(width: 7),
                          DepletingUsageRing(
                            window: primaryWindows[i],
                            size: widget.large ? 56.0 : 33.0,
                            strokeWidth: widget.large ? 4.6 : 3.1,
                            compact: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),

              // Expandable Drawer for Google Antigravity
              if (isAntigravity)
                AntigravityLimitsDrawer(
                  agent: agent,
                  isExpanded: widget.large || widget.isAntigravityExpanded,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpandPillButton extends StatelessWidget {
  final bool isExpanded;
  final int count;
  final VoidCallback? onTap;

  const _ExpandPillButton({
    required this.isExpanded,
    required this.count,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isExpanded
          ? 'Antigravity Modell-Limits einklappen'
          : 'Alle $count Antigravity Modell- & Zeitfenster-Limits anzeigen',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
          decoration: BoxDecoration(
            color: AppConstants.accentAntigravity.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: AppConstants.accentAntigravity.withValues(alpha: 0.38),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Alle ($count)',
                style: const TextStyle(
                  fontSize: 9.2,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.accentAntigravity,
                  fontFeatures: AmpelTheme.tabularFigures,
                  height: 1.1,
                ),
              ),
              Icon(
                isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                size: 12,
                color: AppConstants.accentAntigravity,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
