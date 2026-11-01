import 'package:flutter/material.dart';
import '../../controllers/ampel_controller.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';
import '../theme/ampel_theme.dart';
import '../widgets/agent_logo_widget.dart';
import '../widgets/antigravity_limits_drawer.dart';
import '../widgets/connections_panel.dart';
import '../widgets/depleting_usage_ring.dart';
import '../widgets/traffic_light_widget.dart';

/// Phone layout: a tab bar (Status, Verbindungen) and one card per agent.
class PhoneHomeScreen extends StatefulWidget {
  final AmpelController controller;
  const PhoneHomeScreen({super.key, required this.controller});

  @override
  State<PhoneHomeScreen> createState() => _PhoneHomeScreenState();
}

class _PhoneHomeScreenState extends State<PhoneHomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return Scaffold(
      backgroundColor: AppConstants.bgPrimary,
      body: SafeArea(
        bottom: false,
        child: _tab == 0
            ? _StatusTab(controller: ctrl)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Text('Verbindungen', style: _largeTitle),
                  ),
                  Expanded(child: ConnectionsPanel(controller: ctrl)),
                ],
              ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppConstants.bgCard,
        indicatorColor: AppConstants.ampelGreen.withValues(alpha: 0.18),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.traffic_outlined),
            selectedIcon: Icon(Icons.traffic),
            label: 'Status',
          ),
          NavigationDestination(
            icon: Icon(Icons.link_rounded),
            selectedIcon: Icon(Icons.link_rounded),
            label: 'Verbindungen',
          ),
        ],
      ),
    );
  }
}

const TextStyle _largeTitle = TextStyle(
  fontSize: 30,
  fontWeight: FontWeight.w800,
  letterSpacing: -0.4,
  color: AmpelTheme.textPrimary,
);

class _StatusTab extends StatelessWidget {
  final AmpelController controller;
  const _StatusTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final String hint;
        if (c.pairedByCode) {
          hint = 'Live von deinem Desktop (per QR-Code verbunden).';
        } else if (c.demoMode) {
          hint = 'Demo-Daten. Verbinde deinen Desktop unter „Verbindungen“.';
        } else if (c.remoteSyncHost.isNotEmpty) {
          hint = 'Live von ${c.remoteSyncHost}';
        } else {
          hint = 'Nicht mit einem Desktop verbunden.';
        }
        final cards = <Widget>[
          _PhoneAgentCard(
            agent: c.codexStatus,
            onCycle: () => c.cycleAgentTrafficLight(AgentType.codex),
          ),
          _PhoneAgentCard(
            agent: c.antigravityStatus,
            expanded: c.isAntigravityExpanded,
            onToggle: c.toggleAntigravityExpanded,
            onCycle: () => c.cycleAgentTrafficLight(AgentType.antigravity),
          ),
          _PhoneAgentCard(
            agent: c.claudeStatus,
            onCycle: () => c.cycleAgentTrafficLight(AgentType.claude),
          ),
          for (final a in c.customStatuses)
            _PhoneAgentCard(
              agent: a,
              onCycle: () => c.cycleAgentTrafficLight(AgentType.custom, customId: a.customId),
            ),
        ];
        return RefreshIndicator(
          onRefresh: c.refreshAllUsage,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('Agent Lights', style: _largeTitle),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                child: Text(hint, style: const TextStyle(fontSize: 15, color: AmpelTheme.textSecondary)),
              ),
              for (final w in cards) ...[w, const SizedBox(height: 12)],
            ],
          ),
        );
      },
    );
  }
}

class _PhoneAgentCard extends StatelessWidget {
  final AgentStatusModel agent;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onCycle;

  const _PhoneAgentCard({
    required this.agent,
    this.expanded = false,
    this.onToggle,
    this.onCycle,
  });

  @override
  Widget build(BuildContext context) {
    final state = agent.trafficLight;
    final isAntigravity = agent.agentType == AgentType.antigravity;
    final subLimits = agent.allAntigravitySubLimits.isNotEmpty
        ? agent.allAntigravitySubLimits.length
        : agent.windows.length;
    final Color border = state == TrafficLightState.outOfUsage
        ? AppConstants.ampelRed.withValues(alpha: 0.5)
        : state == TrafficLightState.needsInput
            ? AppConstants.ampelYellow.withValues(alpha: 0.45)
            : AppConstants.borderSubtle;

    return Semantics(
      container: true,
      label: '${agent.title}: ${agent.effectiveSubtitle}',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppConstants.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AgentLogoWidget(
                  agentType: agent.agentType,
                  customColor: agent.customColor,
                  monogram: agent.monogram,
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        agent.title,
                        maxLines: 2,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AmpelTheme.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        agent.effectiveSubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: state == TrafficLightState.outOfUsage
                              ? AppConstants.ampelRed
                              : state == TrafficLightState.needsInput
                                  ? AppConstants.ampelYellow
                                  : AmpelTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                TrafficLightWidget(activeState: state, onTap: onCycle, lampSize: 13),
              ],
            ),
            if (agent.primaryWindows.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final w in agent.primaryWindows)
                    DepletingUsageRing(
                      window: w,
                      size: 68,
                      strokeWidth: 5.4,
                      compact: false,
                      labelSize: 12,
                    ),
                ],
              ),
            ],
            if (isAntigravity) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: onToggle,
                icon: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                label: Text(expanded ? 'Limits einklappen' : 'Alle $subLimits Limits'),
              ),
              AntigravityLimitsDrawer(agent: agent, isExpanded: expanded),
            ],
          ],
        ),
      ),
    );
  }
}
