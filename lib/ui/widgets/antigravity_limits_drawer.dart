import 'package:flutter/material.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';
import '../../models/usage_window.dart';
import '../theme/ampel_theme.dart';
import 'depleting_usage_ring.dart';

class AntigravityLimitsDrawer extends StatelessWidget {
  final AgentStatusModel agent;
  final bool isExpanded;

  const AntigravityLimitsDrawer({
    super.key,
    required this.agent,
    required this.isExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final subLimits = agent.allAntigravitySubLimits.isNotEmpty
        ? agent.allAntigravitySubLimits
        : agent.windows;

    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedCrossFade(
        duration: const Duration(milliseconds: 200),
        crossFadeState: isExpanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        firstChild: const SizedBox(width: double.infinity, height: 0),
        secondChild: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: AppConstants.bgWell.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppConstants.accentAntigravity.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome_mosaic_rounded,
                    size: 13,
                    color: AppConstants.accentAntigravity,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Google Antigravity · Alle Modell- & Zeitfenster-Kontingente (${subLimits.length})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AmpelTheme.textSecondary,
                        letterSpacing: 0.2,
                        fontFeatures: AmpelTheme.tabularFigures,
                      ),
                    ),
                  ),
                  if (agent.detail.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        agent.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: AmpelTheme.textMuted,
                          fontFeatures: AmpelTheme.tabularFigures,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final maxW = constraints.maxWidth;
                  final columns = maxW >= 360 ? 2 : 1;
                  const spacing = 6.0;
                  final itemWidth = columns == 2
                      ? (maxW - spacing) / 2
                      : maxW;

                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: subLimits.map((window) {
                      return SizedBox(
                        width: itemWidth,
                        child: _SubLimitTile(window: window),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubLimitTile extends StatelessWidget {
  final UsageWindow window;

  const _SubLimitTile({required this.window});

  @override
  Widget build(BuildContext context) {
    final hasData = !window.disabled && window.usedPercent != null;
    final isCritical = window.isCritical;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppConstants.bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCritical
              ? AppConstants.ringCritical.withValues(alpha: 0.45)
              : AppConstants.borderSubtle,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          DepletingUsageRing(
            window: window,
            size: 32,
            strokeWidth: 3.0,
            showLabels: false,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  window.fullTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.0,
                    fontWeight: FontWeight.w600,
                    color: AmpelTheme.textPrimary,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        hasData
                            ? '${window.remainingPercentLabel} übrig (${window.usedPercent!.round()}% genutzt)'
                            : window.quotaLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.8,
                          fontWeight: FontWeight.w500,
                          color: isCritical
                              ? AppConstants.ringCritical
                              : AmpelTheme.textSecondary,
                          fontFeatures: AmpelTheme.tabularFigures,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1.5),
                Text(
                  resetLabel(window),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9.0,
                    color: AmpelTheme.textMuted,
                    fontFeatures: AmpelTheme.tabularFigures,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
