import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../controllers/ampel_controller.dart';
import '../../models/app_constants.dart';
import '../../models/custom_agent.dart';
import '../../services/platform/platform_bridge.dart';
import '../theme/ampel_theme.dart';

class _Service {
  final String name;
  final String how;
  final String url;
  final Color color;
  final bool Function(AmpelController) connected;

  /// Set for providers without a limit interface: they become a custom agent.
  final CustomAgent? asCustomAgent;

  const _Service({
    required this.name,
    required this.how,
    required this.url,
    required this.color,
    required this.connected,
    this.asCustomAgent,
  });
}

final List<_Service> _services = [
  _Service(
    name: 'Claude Code',
    how: 'Liest deine echten 5-Stunden- und Wochen-Limits aus Claude Code. '
        'Starte dafür einmal eine Claude-Code-Sitzung auf dem Desktop.',
    url: 'https://claude.ai/settings/usage',
    color: AppConstants.accentClaude,
    connected: (c) => c.claudeStatus.authenticated && c.claudeStatus.windows.any((w) => w.usedPercent != null),
  ),
  _Service(
    name: 'OpenAI Codex (ChatGPT)',
    how: 'Nutzt die Anmeldung der Codex-CLI auf deinem Rechner. Einmal `codex login` im Terminal.',
    url: 'https://chatgpt.com',
    color: AppConstants.accentCodex,
    connected: (c) => c.codexStatus.authenticated,
  ),
  _Service(
    name: 'Google Antigravity (Gemini)',
    how: 'Liest das lokale Antigravity-Konto. Melde dich in Antigravity mit deinem Google-Konto an.',
    url: 'https://gemini.google.com',
    color: AppConstants.accentAntigravity,
    connected: (c) => c.antigravityStatus.authenticated,
  ),
  _Service(
    name: 'Grok',
    how: 'Keine öffentliche Limit-Schnittstelle. Wird als eigener Agent geführt und meldet seinen Status per Hook.',
    url: 'https://grok.com',
    color: const Color(0xFFE2E8F0),
    connected: (c) => c.customAgents.any((a) => a.id == 'grok'),
    asCustomAgent: const CustomAgent(id: 'grok', name: 'Grok', colorValue: 0xFFE2E8F0),
  ),
  _Service(
    name: 'DeepSeek',
    how: 'Keine öffentliche Limit-Schnittstelle. Wird als eigener Agent geführt und meldet seinen Status per Hook.',
    url: 'https://chat.deepseek.com',
    color: const Color(0xFF6C8CFF),
    connected: (c) => c.customAgents.any((a) => a.id == 'deepseek'),
    asCustomAgent: const CustomAgent(id: 'deepseek', name: 'DeepSeek', colorValue: 0xFF6C8CFF),
  ),
  _Service(
    name: 'Kimi',
    how: 'Keine öffentliche Limit-Schnittstelle. Wird als eigener Agent geführt und meldet seinen Status per Hook.',
    url: 'https://www.kimi.com',
    color: const Color(0xFF5EEAD4),
    connected: (c) => c.customAgents.any((a) => a.id == 'kimi'),
    asCustomAgent: const CustomAgent(id: 'kimi', name: 'Kimi', colorValue: 0xFF5EEAD4),
  ),
];

/// Sign-in and connection overview. Agent Lights has no accounts of its own: it reuses the logins
/// of the agents on the desktop, and phones/web pair with the desktop.
class ConnectionsPanel extends StatelessWidget {
  final AmpelController controller;
  final EdgeInsets padding;

  const ConnectionsPanel({
    super.key,
    required this.controller,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return ListView(
          padding: padding,
          children: [
            const Text(
              'Agent Lights hat keine eigenen Konten. Es nutzt die Anmeldungen, die deine Agenten '
              'schon haben. Nichts davon verlässt deinen Rechner.',
              style: TextStyle(fontSize: 15, height: 1.35, color: AmpelTheme.textSecondary),
            ),
            const SizedBox(height: 20),
            if (PlatformBridge.isDesktop) ...[
              _SectionTitle('Handy verbinden'),
              _RemoteAccessCard(controller: controller),
              const SizedBox(height: 20),
            ] else ...[
              _SectionTitle('Desktop verbinden'),
              _JoinCard(controller: controller),
              const SizedBox(height: 10),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: const Text(
                    'Im selben WLAN (Adresse eingeben)',
                    style: TextStyle(fontSize: 14, color: AmpelTheme.textSecondary),
                  ),
                  children: [_PairCard(controller: controller)],
                ),
              ),
              const SizedBox(height: 10),
            ],
            _SectionTitle('Dienste'),
            for (final s in _services) ...[
              _ServiceTile(service: s, controller: controller),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class ConnectionsDialog {
  static Future<void> show(BuildContext context, AmpelController controller) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppConstants.bgPrimary,
        insetPadding: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppConstants.borderSubtle),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Verbindungen',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AmpelTheme.textPrimary),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Schließen',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded, color: AmpelTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              Expanded(child: ConnectionsPanel(controller: controller)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: AmpelTheme.textMuted),
        ),
      );
}

class _CardShell extends StatelessWidget {
  final Widget child;
  const _CardShell({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppConstants.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppConstants.borderSubtle),
        ),
        child: child,
      );
}

class _PairCard extends StatefulWidget {
  final AmpelController controller;
  const _PairCard({required this.controller});

  @override
  State<_PairCard> createState() => _PairCardState();
}

class _PairCardState extends State<_PairCard> {
  late final TextEditingController _host =
      TextEditingController(text: widget.controller.remoteSyncHost);

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final paired = c.remoteSyncHost.isNotEmpty && !c.demoMode;
    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paired ? 'Verbunden mit ${c.remoteSyncHost}' : 'Noch nicht verbunden',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: paired ? AppConstants.ampelGreen : AmpelTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Öffne Agent Lights auf dem Desktop (Einstellungen: LAN-Zugriff erlauben) und gib hier '
            'dessen Adresse ein, zum Beispiel 192.168.1.50:47832. Handy und Desktop müssen im selben WLAN sein.',
            style: TextStyle(fontSize: 14, height: 1.35, color: AmpelTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(fontSize: 17, color: AmpelTheme.textPrimary),
            decoration: InputDecoration(
              hintText: '192.168.1.50:47832',
              filled: true,
              fillColor: AppConstants.bgWell,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: () async {
                await c.setRemoteSyncHost(_host.text);
                if (c.remoteSyncHost.isNotEmpty) await c.setDemoMode(false);
              },
              child: const Text('Mit Desktop verbinden'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  final _Service service;
  final AmpelController controller;
  const _ServiceTile({required this.service, required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = service;
    final connected = s.connected(controller);
    final custom = s.asCustomAgent;
    final statusText = custom != null
        ? (connected ? 'Hinzugefügt' : 'Nicht hinzugefügt')
        : (connected ? 'Verbunden' : 'Nicht verbunden');
    final statusColor = connected ? AppConstants.ampelGreen : AmpelTheme.textMuted;

    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.name,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AmpelTheme.textPrimary),
                ),
              ),
              Icon(connected ? Icons.check_circle_rounded : Icons.circle_outlined, size: 18, color: statusColor),
              const SizedBox(width: 6),
              Text(statusText, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: statusColor)),
            ],
          ),
          const SizedBox(height: 8),
          Text(s.how, style: const TextStyle(fontSize: 14, height: 1.35, color: AmpelTheme.textSecondary)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (custom != null)
                FilledButton.tonal(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => connected
                      ? controller.removeCustomAgent(custom.id)
                      : controller.saveCustomAgent(custom),
                  child: Text(connected ? 'Entfernen' : 'Hinzufügen'),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => launchUrl(Uri.parse(s.url), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text('${s.name.split(' ').first} öffnen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Desktop: shows the QR code. Scanning it with the phone camera opens the web app, already paired.
class _RemoteAccessCard extends StatelessWidget {
  final AmpelController controller;
  const _RemoteAccessCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final on = c.remoteAccessEnabled;
    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Fernzugriff per QR-Code',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AmpelTheme.textPrimary),
            ),
            subtitle: const Text(
              'Zeigt deinen Status auf dem Handy, auch außerhalb deines WLANs.',
              style: TextStyle(fontSize: 14, color: AmpelTheme.textSecondary),
            ),
            value: on,
            onChanged: (v) => c.setRemoteAccess(v),
          ),
          if (on) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(data: c.pairUrl, size: 200, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Handy-Kamera auf den Code richten und den Link öffnen. Fertig: Agent Lights im Browser ist verbunden.',
              style: TextStyle(fontSize: 14, height: 1.35, color: AmpelTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => Clipboard.setData(ClipboardData(text: c.pairUrl)),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Link kopieren'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => c.setRemoteAccess(true, renew: true),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Neuen Code erzeugen'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Übertragen werden nur Status und Prozentwerte, über den Dienst ntfy.sh unter einem '
              'geheimen Zufallsnamen. Mit "Neuen Code erzeugen" sperrst du alle bisherigen Handys aus.',
              style: TextStyle(fontSize: 12, height: 1.35, color: AmpelTheme.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Phone/web: pair with the desktop by pasting the link or code from the QR code.
class _JoinCard extends StatefulWidget {
  final AmpelController controller;
  const _JoinCard({required this.controller});

  @override
  State<_JoinCard> createState() => _JoinCardState();
}

class _JoinCardState extends State<_JoinCard> {
  final TextEditingController _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final paired = c.pairedByCode;
    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paired ? 'Mit deinem Desktop verbunden' : 'Noch nicht verbunden',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: paired ? AppConstants.ampelGreen : AmpelTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Am Desktop in Agent Lights unter Verbindungen den Fernzugriff einschalten. '
            'Dann den QR-Code mit der Kamera dieses Handys scannen. Das geht von überall, nicht nur im WLAN.',
            style: TextStyle(fontSize: 14, height: 1.35, color: AmpelTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autocorrect: false,
            style: const TextStyle(fontSize: 17, color: AmpelTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'Link oder Code einfügen',
              errorText: _error,
              filled: true,
              fillColor: AppConstants.bgWell,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: () async {
                final ok = await c.joinWithCode(_code.text);
                setState(() => _error = ok ? null : 'Das ist kein gültiger Code.');
              },
              child: const Text('Verbinden'),
            ),
          ),
          if (paired) ...[
            const SizedBox(height: 4),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: c.leaveRemote,
              child: const Text('Verbindung trennen'),
            ),
          ],
        ],
      ),
    );
  }
}
