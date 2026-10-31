import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../controllers/ampel_controller.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';
import '../../services/platform/platform_bridge.dart';
import '../widgets/agent_row_card.dart';
import '../widgets/hud_top_bar.dart';
import '../widgets/settings_dialog.dart';

class AmpelHudScreen extends StatefulWidget {
  final AmpelController controller;

  const AmpelHudScreen({
    super.key,
    required this.controller,
  });

  @override
  State<AmpelHudScreen> createState() => _AmpelHudScreenState();
}

class _AmpelHudScreenState extends State<AmpelHudScreen> {
  final FocusNode _keyboardFocusNode = FocusNode();

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape &&
          PlatformBridge.isDesktop) {
        widget.controller.desktopIntegration.hideWindowToTray();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.f5) {
        widget.controller.refreshAllUsage();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = PlatformBridge.isDesktop;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: isDesktop ? Colors.transparent : AppConstants.bgPrimary,
        body: SafeArea(
          top: !isDesktop,
          bottom: !isDesktop,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppConstants.bgPrimary, // #0B0E14
              borderRadius: isDesktop
                  ? BorderRadius.circular(16)
                  : BorderRadius.zero,
              border: isDesktop
                  ? Border.all(
                      color: AppConstants.borderSubtle, // #1E293B
                      width: 1.0,
                    )
                  : null,
              boxShadow: isDesktop
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.55),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final ctrl = widget.controller;

                return Column(
                  children: [
                    // Compact Spotlight / Raycast Top-Bar
                    HudTopBar(
                      controller: ctrl,
                      onOpenSettings: () =>
                          SettingsDialog.show(context, ctrl),
                      updateAvailableTag: ctrl.updateAvailable
                          ? 'v${ctrl.latestVersion}'
                          : null,
                      onUpdateBadgeTap: () => ctrl.downloadAndInstallUpdate(),
                    ),

                    // Scrollable Main HUD Body (3 Agent Rows + Expandable Antigravity Drawer)
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 1. OpenAI Codex
                            AgentRowCard(
                              agent: ctrl.codexStatus,
                              onCycleTrafficLight: () => ctrl
                                  .cycleAgentTrafficLight(AgentType.codex),
                            ),
                            const SizedBox(height: 5),

                            // 2. Google Antigravity (Expandable/Collapsible Sub-Limits)
                            AgentRowCard(
                              agent: ctrl.antigravityStatus,
                              isAntigravityExpanded:
                                  ctrl.isAntigravityExpanded,
                              onToggleExpand: () =>
                                  ctrl.toggleAntigravityExpanded(),
                              onCycleTrafficLight: () =>
                                  ctrl.cycleAgentTrafficLight(
                                AgentType.antigravity,
                              ),
                            ),
                            const SizedBox(height: 5),

                            // 3. Claude Code
                            AgentRowCard(
                              agent: ctrl.claudeStatus,
                              onCycleTrafficLight: () => ctrl
                                  .cycleAgentTrafficLight(AgentType.claude),
                            ),
                            for (final c in ctrl.customStatuses) ...[
                              const SizedBox(height: 5),
                              AgentRowCard(
                                agent: c,
                                onCycleTrafficLight: () =>
                                    ctrl.cycleAgentTrafficLight(
                                  AgentType.custom,
                                  customId: c.customId,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
