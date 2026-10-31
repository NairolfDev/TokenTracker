import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../../controllers/ampel_controller.dart';
import '../../models/app_constants.dart';
import '../../services/platform/platform_bridge.dart';
import '../theme/ampel_theme.dart';

class HudTopBar extends StatefulWidget {
  final AmpelController controller;
  final VoidCallback onOpenSettings;
  final String? updateAvailableTag;
  final VoidCallback? onUpdateBadgeTap;

  const HudTopBar({
    super.key,
    required this.controller,
    required this.onOpenSettings,
    this.updateAvailableTag,
    this.onUpdateBadgeTap,
  });

  @override
  State<HudTopBar> createState() => _HudTopBarState();
}

class _HudTopBarState extends State<HudTopBar> {
  Future<void> _togglePin() async {
    final next = !widget.controller.desktopIntegration.alwaysOnTop;
    await widget.controller.desktopIntegration.setAlwaysOnTop(next);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final isDesktop = PlatformBridge.isDesktop;
    final serverUp = controller.isHookServerRunning;
    final isPinned = controller.desktopIntegration.alwaysOnTop;

    final headerContent = Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0E131B),
        border: Border(
          bottom: BorderSide(color: AppConstants.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Live Server / Sync Indicator Dot
          Tooltip(
            message: serverUp
                ? 'Lokaler Hook-Server aktiv (127.0.0.1:${AppConstants.hookServerPort})'
                : (controller.remoteSyncHost.isNotEmpty
                    ? 'Remote-Sync (${controller.remoteSyncHost})'
                    : 'Lokaler Modus / Hook-Server Standby'),
            child: Container(
              width: 7.5,
              height: 7.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: serverUp || controller.demoMode
                    ? AppConstants.ampelGreen
                    : AppConstants.ampelYellow,
                boxShadow: [
                  BoxShadow(
                    color: (serverUp || controller.demoMode
                            ? AppConstants.ampelGreen
                            : AppConstants.ampelYellow)
                        .withValues(alpha: 0.6),
                    blurRadius: 5,
                    spreadRadius: 0.8,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 7),

          // Compact HUD Title
          const Flexible(
            child: Text(
              'AGENT LIGHTS',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
                color: AmpelTheme.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 6),

          // Subtle Port / Mode Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: AppConstants.bgWell,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppConstants.borderSubtle, width: 0.8),
            ),
            child: Text(
              controller.demoMode
                  ? 'DEMO'
                  : ':${AppConstants.hookServerPort}',
              style: TextStyle(
                fontSize: 9.0,
                fontWeight: FontWeight.w600,
                color: controller.demoMode
                    ? AppConstants.ampelYellow
                    : AmpelTheme.textMuted,
                fontFeatures: AmpelTheme.tabularFigures,
              ),
            ),
          ),

          if ((widget.updateAvailableTag != null &&
                  widget.updateAvailableTag!.isNotEmpty) ||
              controller.updateAvailable) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: widget.onUpdateBadgeTap ??
                  () => controller.downloadAndInstallUpdate(),
              borderRadius: BorderRadius.circular(5),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: AppConstants.ampelGreen.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: AppConstants.ampelGreen.withValues(alpha: 0.45),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  '↑ ${widget.updateAvailableTag ?? 'v${controller.latestVersion}'}',
                  style: const TextStyle(
                    fontSize: 9.0,
                    fontWeight: FontWeight.w700,
                    color: AppConstants.ampelGreen,
                    fontFeatures: AmpelTheme.tabularFigures,
                  ),
                ),
              ),
            ),
          ],

          const Spacer(),

          // Refresh Button
          _TopBarIconButton(
            tooltip: 'Quotas & Status jetzt aktualisieren',
            onTap: controller.isRefreshing
                ? null
                : () => controller.refreshAllUsage(),
            child: controller.isRefreshing
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: AmpelTheme.textPrimary,
                    ),
                  )
                : const Icon(
                    Icons.refresh_rounded,
                    size: 14,
                    color: AmpelTheme.textSecondary,
                  ),
          ),

          // Compact HUD <-> large window (Desktop)
          if (isDesktop) ...[
            const SizedBox(width: 2),
            _TopBarIconButton(
              tooltip: 'Große Ansicht / Kompakt umschalten',
              onTap: () async {
                await controller.desktopIntegration.toggleLargeWindow();
                if (mounted) setState(() {});
              },
              child: Icon(
                MediaQuery.sizeOf(context).width >= AppConstants.largeLayoutWidth
                    ? Icons.close_fullscreen_rounded
                    : Icons.open_in_full_rounded,
                size: 13.5,
                color: AmpelTheme.textSecondary,
              ),
            ),
          ],

          // Always-on-Top Pin Button (Desktop)
          if (isDesktop) ...[
            const SizedBox(width: 2),
            _TopBarIconButton(
              tooltip: isPinned
                  ? 'Immer im Vordergrund (Aktiv)'
                  : 'Immer im Vordergrund anheften',
              isActive: isPinned,
              onTap: _togglePin,
              child: Icon(
                isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 13.5,
                color: isPinned
                    ? const Color(0xFF38BDF8)
                    : AmpelTheme.textSecondary,
              ),
            ),
          ],

          // Settings Gear Button
          const SizedBox(width: 2),
          _TopBarIconButton(
            tooltip: 'Einstellungen, Hooks & Diagnose',
            onTap: widget.onOpenSettings,
            child: const Icon(
              Icons.settings_outlined,
              size: 14,
              color: AmpelTheme.textSecondary,
            ),
          ),

          // Hide to Tray Button (Desktop)
          if (isDesktop) ...[
            const SizedBox(width: 2),
            _TopBarIconButton(
              tooltip: 'In System-Tray ausblenden (Esc / Alt+Space)',
              onTap: () => controller.desktopIntegration.hideWindowToTray(),
              child: const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 15.5,
                color: AmpelTheme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );

    if (isDesktop) {
      return DragToMoveArea(child: headerContent);
    }
    return headerContent;
  }
}

class _TopBarIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;
  final bool isActive;

  const _TopBarIconButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 24,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF38BDF8).withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: child,
        ),
      ),
    );
  }
}
