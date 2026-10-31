import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../controllers/ampel_controller.dart';
import '../../models/agent_status.dart';
import '../../models/app_constants.dart';
import '../../models/custom_agent.dart';
import '../../services/hook_event.dart';
import '../../services/platform/platform_bridge.dart';
import '../theme/ampel_theme.dart';

class SettingsDialog extends StatefulWidget {
  final AmpelController controller;

  const SettingsDialog({
    super.key,
    required this.controller,
  });

  static Future<void> show(BuildContext context, AmpelController controller) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.68),
      builder: (_) => SettingsDialog(controller: controller),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late TextEditingController _remoteHostController;
  String _feedbackMessage = '';
  bool _busyHooks = false;

  @override
  void initState() {
    super.initState();
    _remoteHostController = TextEditingController(
      text: widget.controller.remoteSyncHost,
    );
  }

  @override
  void dispose() {
    _remoteHostController.dispose();
    super.dispose();
  }

  Future<void> _reinstallHooks() async {
    setState(() {
      _busyHooks = true;
      _feedbackMessage = '';
    });
    final res = await widget.controller.reinstallHooks();
    if (!mounted) return;
    setState(() {
      _busyHooks = false;
      _feedbackMessage = res.updatedFiles.isNotEmpty
          ? 'Hooks aktualisiert (${res.updatedFiles.length} Dateien, .bak gesichert).'
          : 'Hook-Konfiguration geprüft.';
    });
  }

  void _triggerTestState(TrafficLightState state) {
    final String detail;
    final bool isError = state == TrafficLightState.outOfUsage;
    switch (state) {
      case TrafficLightState.outOfUsage:
        detail = 'Test: Limit erreicht / Rate-Limit';
        break;
      case TrafficLightState.needsInput:
        detail = 'Test: Wartet auf Freigabe';
        break;
      case TrafficLightState.working:
        detail = 'Test: Führt Tool aus...';
        break;
      case TrafficLightState.idle:
        detail = 'Bereit (Idle)';
        break;
    }

    final now = DateTime.now();
    for (final agent in AgentType.values) {
      widget.controller.handleHookEvent(
        HookEventPayload(
          agent: agent,
          targetState: state,
          isErrorEvent: isError,
          shouldRefreshUsage: false,
          detail: detail,
          timestamp: now,
        ),
      );
    }
    setState(() {
      _feedbackMessage = 'Alle 3 Agenten auf "${state.name}" geschaltet.';
    });
  }

  Future<void> _editCustomAgent(CustomAgent? existing) async {
    final result = await showDialog<CustomAgent>(
      context: context,
      builder: (_) => _CustomAgentDialog(existing: existing),
    );
    if (result != null) await widget.controller.saveCustomAgent(result);
  }

  Future<void> _openGithubReleases() async {
    widget.controller.onUpdateCheckTriggered?.call();
    final hasNewer = await widget.controller.checkForUpdates(silent: false);
    if (!mounted) return;
    setState(() {
      _feedbackMessage = widget.controller.updateStatusMessage;
    });
    if (hasNewer) {
      await widget.controller.downloadAndInstallUpdate();
      if (!mounted) return;
      setState(() {
        _feedbackMessage = widget.controller.updateStatusMessage;
      });
      return;
    }
    final url = Uri.parse(
      'https://github.com/${AppConstants.githubOwner}/${AppConstants.githubRepo}/releases',
    );
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        final isDesktop = PlatformBridge.isDesktop;

        return Dialog(
          backgroundColor: AppConstants.bgCard,
          insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppConstants.borderSubtle, width: 1),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Modal Header
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: const BoxDecoration(
                    color: AppConstants.bgPrimary,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(14)),
                    border: Border(
                      bottom:
                          BorderSide(color: AppConstants.borderSubtle, width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.tune_rounded,
                        size: 16,
                        color: Color(0xFF38BDF8),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Einstellungen · Hooks & System-HUD',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AmpelTheme.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        color: AmpelTheme.textSecondary,
                      ),
                    ],
                  ),
                ),

                // Scrollable Settings Body
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isDesktop) ...[
                          _SectionHeader(title: 'DESKTOP & FENSTER'),
                          _SwitchRow(
                            title: 'Mit System starten (Autostart)',
                            subtitle:
                                'Startet die Agent-Ampel automatisch im Hintergrund',
                            value: ctrl.desktopIntegration.autostartEnabled,
                            onChanged: (val) async {
                              await ctrl.desktopIntegration
                                  .setAutostartEnabled(val);
                              if (mounted) setState(() {});
                            },
                          ),
                          const SizedBox(height: 6),
                          _SwitchRow(
                            title: 'Immer im Vordergrund (Always on Top)',
                            subtitle:
                                'Hält das HUD über allen Fenstern (Hotkey: Alt + Space)',
                            value: ctrl.desktopIntegration.alwaysOnTop,
                            onChanged: (val) async {
                              await ctrl.desktopIntegration.setAlwaysOnTop(val);
                              if (mounted) setState(() {});
                            },
                          ),
                          const SizedBox(height: 12),
                        ],

                        _SectionHeader(
                          title: 'AUTO-HOOKS (127.0.0.1:${AppConstants.hookServerPort})',
                        ),
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: AppConstants.bgWell,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: AppConstants.borderSubtle,
                              width: 1,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _HookStatusLine(
                                label: 'OpenAI Codex (~/.codex/hooks.json)',
                                installed: ctrl.codexStatus.hookInstalled,
                              ),
                              const SizedBox(height: 4),
                              _HookStatusLine(
                                label:
                                    'Google Antigravity (~/.gemini/config/hooks.json)',
                                installed: ctrl.antigravityStatus.hookInstalled,
                              ),
                              const SizedBox(height: 4),
                              _HookStatusLine(
                                label: 'Claude Code (~/.claude/settings.json)',
                                installed: ctrl.claudeStatus.hookInstalled,
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _busyHooks ? null : _reinstallHooks,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AmpelTheme.textPrimary,
                                    side: const BorderSide(
                                      color: AppConstants.borderSubtle,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 10,
                                    ),
                                  ),
                                  icon: _busyHooks
                                      ? const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.6,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.build_circle_outlined,
                                          size: 14,
                                        ),
                                  label: const Text(
                                    'Hooks jetzt prüfen / neu installieren (mit .bak Backup)',
                                    style: TextStyle(fontSize: 10.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),
                        _SectionHeader(title: 'SIMULATION & KAMMER-TESTER'),
                        _SwitchRow(
                          title: 'Demo- & Simulations-Modus',
                          subtitle:
                              'Zeigt Beispiel-Quotas für alle 3 Provider (inkl. Antigravity Sub-Limits)',
                          value: ctrl.demoMode,
                          onChanged: (val) => ctrl.setDemoMode(val),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _TestLampButton(
                              label: 'Kammer 1: ROT',
                              color: AppConstants.ampelRed,
                              onTap: () =>
                                  _triggerTestState(TrafficLightState.outOfUsage),
                            ),
                            _TestLampButton(
                              label: 'Kammer 2: GELB',
                              color: AppConstants.ampelYellow,
                              onTap: () =>
                                  _triggerTestState(TrafficLightState.needsInput),
                            ),
                            _TestLampButton(
                              label: 'Kammer 3: GRÜN',
                              color: AppConstants.ampelGreen,
                              onTap: () =>
                                  _triggerTestState(TrafficLightState.working),
                            ),
                            _TestLampButton(
                              label: 'Kammer 4: WEISS',
                              color: AppConstants.ampelWhite,
                              onTap: () =>
                                  _triggerTestState(TrafficLightState.idle),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),
                        _SectionHeader(title: 'EIGENE AGENTEN (KIMI, GROK, ...)'),
                        for (final c in ctrl.customAgents) ...[
                          _CustomAgentRow(
                            agent: c,
                            onEdit: () => _editCustomAgent(c),
                            onDelete: () => ctrl.removeCustomAgent(c.id),
                          ),
                          const SizedBox(height: 6),
                        ],
                        OutlinedButton.icon(
                          onPressed: () => _editCustomAgent(null),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AmpelTheme.textPrimary,
                            side: const BorderSide(color: AppConstants.borderSubtle),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 14),
                          label: const Text('Agent hinzufügen', style: TextStyle(fontSize: 11)),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            'Status per POST an /api/hook, z. B. {"agent":"kimi","event":"working","usage":{"5h":40}}',
                            style: TextStyle(fontSize: 10, color: AmpelTheme.textMuted),
                          ),
                        ),

                        const SizedBox(height: 12),
                        _SectionHeader(title: 'NETZWERK & MOBILE / WEB SYNC'),
                        if (isDesktop) ...[
                          _SwitchRow(
                            title:
                                'Hook-Server im LAN freigeben (0.0.0.0:${AppConstants.hookServerPort})',
                            subtitle:
                                'Erlaubt Android/Web-Geräten im selben WLAN die Live-Synchronisation',
                            value: ctrl.bindLanServer,
                            onChanged: (val) => ctrl.setBindLanServer(val),
                          ),
                          const SizedBox(height: 6),
                        ],
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _remoteHostController,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AmpelTheme.textPrimary,
                                  fontFeatures: AmpelTheme.tabularFigures,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  hintText:
                                      'Desktop Sync-Host (z. B. 192.168.1.50:47832)',
                                  hintStyle: const TextStyle(
                                    fontSize: 10.5,
                                    color: AmpelTheme.textMuted,
                                  ),
                                  filled: true,
                                  fillColor: AppConstants.bgWell,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                      color: AppConstants.borderSubtle,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton(
                              onPressed: () {
                                ctrl.setRemoteSyncHost(
                                  _remoteHostController.text,
                                );
                                setState(() {
                                  _feedbackMessage =
                                      'Sync-Host gespeichert: ${_remoteHostController.text.isEmpty ? "Lokal" : _remoteHostController.text}';
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AmpelTheme.textPrimary,
                                side: const BorderSide(
                                  color: AppConstants.borderSubtle,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                              child: const Text(
                                'Verbinden',
                                style: TextStyle(fontSize: 10.5),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),
                        _SectionHeader(title: 'UPDATES & REPOSITORY'),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'GitHub: ${AppConstants.githubOwner}/${AppConstants.githubRepo} (v${ctrl.currentVersion})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AmpelTheme.textSecondary,
                                      fontFeatures: AmpelTheme.tabularFigures,
                                    ),
                                  ),
                                  if (ctrl.updateAvailable)
                                    Text(
                                      'Neu verfügbar: v${ctrl.latestVersion}',
                                      style: const TextStyle(
                                        fontSize: 9.8,
                                        fontWeight: FontWeight.w600,
                                        color: AppConstants.ampelGreen,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: ctrl.isCheckingForUpdates ||
                                      ctrl.isDownloadingUpdate
                                  ? null
                                  : (ctrl.updateAvailable
                                      ? () => ctrl.downloadAndInstallUpdate()
                                      : _openGithubReleases),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: ctrl.updateAvailable
                                    ? AppConstants.ampelGreen
                                    : const Color(0xFF38BDF8),
                                side: BorderSide(
                                  color: ctrl.updateAvailable
                                      ? AppConstants.ampelGreen
                                          .withValues(alpha: 0.5)
                                      : AppConstants.borderSubtle,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              icon: Icon(
                                ctrl.updateAvailable
                                    ? Icons.download_rounded
                                    : Icons.system_update_alt_rounded,
                                size: 13,
                              ),
                              label: Text(
                                ctrl.updateAvailable
                                    ? 'Update v${ctrl.latestVersion} installieren'
                                    : 'Nach Updates suchen',
                                style: const TextStyle(fontSize: 10.5),
                              ),
                            ),
                          ],
                        ),

                        if (_feedbackMessage.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  AppConstants.ampelGreen.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: AppConstants.ampelGreen
                                    .withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              _feedbackMessage,
                              style: const TextStyle(
                                fontSize: 10.2,
                                color: AppConstants.ampelGreen,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: AmpelTheme.textMuted,
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppConstants.bgWell,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppConstants.borderSubtle, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AmpelTheme.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: AmpelTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 24,
            child: Switch(
              value: value,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _HookStatusLine extends StatelessWidget {
  final String label;
  final bool installed;

  const _HookStatusLine({
    required this.label,
    required this.installed,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          installed ? Icons.check_circle_rounded : Icons.info_outline_rounded,
          size: 13,
          color:
              installed ? AppConstants.ampelGreen : AppConstants.ampelYellow,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10.2,
              color: AmpelTheme.textSecondary,
              fontFeatures: AmpelTheme.tabularFigures,
            ),
          ),
        ),
      ],
    );
  }
}

class _TestLampButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TestLampButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AmpelTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomAgentRow extends StatelessWidget {
  final CustomAgent agent;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CustomAgentRow({
    required this.agent,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppConstants.bgWell,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppConstants.borderSubtle, width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: agent.color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${agent.name}  ·  id: ${agent.id}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AmpelTheme.textPrimary),
            ),
          ),
          IconButton(
            tooltip: 'Bearbeiten',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 14),
            color: AmpelTheme.textSecondary,
          ),
          IconButton(
            tooltip: 'Entfernen',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, size: 14),
            color: AmpelTheme.textSecondary,
          ),
        ],
      ),
    );
  }
}

class _CustomAgentDialog extends StatefulWidget {
  final CustomAgent? existing;

  const _CustomAgentDialog({this.existing});

  @override
  State<_CustomAgentDialog> createState() => _CustomAgentDialogState();
}

class _CustomAgentDialogState extends State<_CustomAgentDialog> {
  static const _palette = [
    0xFF38BDF8, 0xFFA78BFA, 0xFFF472B6, 0xFFFB923C,
    0xFF34D399, 0xFFFACC15, 0xFF94A3B8, 0xFFF87171,
  ];

  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _limits =
      TextEditingController(text: widget.existing?.limits ?? '');
  late int _color = widget.existing?.colorValue ?? _palette.first;

  @override
  void dispose() {
    _name.dispose();
    _limits.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final id = widget.existing?.id ?? CustomAgent.slug(name);
    if (name.isEmpty || id.isEmpty) return;
    Navigator.of(context).pop(
      CustomAgent(id: id, name: name, colorValue: _color, limits: _limits.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppConstants.bgCard,
      title: Text(
        widget.existing == null ? 'Agent hinzufügen' : 'Agent bearbeiten',
        style: const TextStyle(fontSize: 14, color: AmpelTheme.textPrimary),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name (z. B. Kimi) – wird zur Hook-ID',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _limits,
              decoration: const InputDecoration(
                labelText: 'Limits (z. B. 5h=40, Woche=12)',
                helperText: 'Label=Verbrauch in %, per Hook "usage" aktualisierbar',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final c in _palette)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(c),
                        border: Border.all(
                          color: c == _color ? Colors.white : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }
}
