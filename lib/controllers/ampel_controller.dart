import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/agent_status.dart';
import '../models/provider_stats.dart';
import '../models/usage_window.dart';
import '../services/auto_updater_service.dart';
import '../services/desktop_integration_service.dart';
import '../services/hook_installer_service.dart';
import '../services/hook_server_service.dart';
import '../services/platform/platform_bridge.dart';
import '../services/usage/antigravity_usage_service.dart';
import '../models/custom_agent.dart';
import '../services/notification_service.dart';
import '../services/relay_sync_service.dart';
import '../services/usage/claude_usage_service.dart';
import '../services/usage/codex_usage_service.dart';
import '../services/usage/usage_cache_service.dart';

class AmpelController extends ChangeNotifier {
  final AntigravityUsageService antigravityService;
  final CodexUsageService codexService;
  final ClaudeUsageService claudeService;
  final UsageCacheService cacheService;
  final HookInstallerService hookInstallerService;
  final AutoUpdaterService autoUpdaterService;

  late final HookServerService hookServerService;
  late final DesktopIntegrationService desktopIntegration;

  final Map<AgentType, AgentStatusModel> _agents = {};
  final Map<String, AgentStatusModel> _customStatus = {};
  List<CustomAgent> _customConfigs = [];
  bool _isRefreshing = false;
  bool _isAntigravityExpanded = false;
  bool _bindLanServer = false;
  String _remoteSyncHost = '';
  bool _demoMode = false;
  String _statusBannerMessage = '';
  VoidCallback? onUpdateCheckTriggered;

  Timer? _usagePollTimer;
  Timer? _activityWatchTimer;

  // Remote pairing (QR code): the desktop publishes, phones and the web app read.
  final RelaySyncService relay = RelaySyncService();
  bool _remoteAccess = false;
  String _pairSecret = '';
  String _joinSecret = '';
  Timer? _relayTimer;
  DateTime _lastRelayPublish = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastRelayBody = '';

  AmpelController({
    AntigravityUsageService? antigravityService,
    CodexUsageService? codexService,
    ClaudeUsageService? claudeService,
    UsageCacheService? cacheService,
    HookInstallerService? hookInstallerService,
    AutoUpdaterService? autoUpdaterService,
  })  : antigravityService = antigravityService ?? AntigravityUsageService(),
        codexService = codexService ?? CodexUsageService(),
        claudeService = claudeService ?? const ClaudeUsageService(),
        cacheService = cacheService ?? UsageCacheService(),
        hookInstallerService = hookInstallerService ?? HookInstallerService(),
        autoUpdaterService =
            autoUpdaterService ?? AutoUpdaterService(autoStart: false) {
    _initDefaultAgents();
    addListener(_notifyOnRedTransition);
    addListener(_scheduleRelayPublish);

    this.autoUpdaterService.addListener(_onAutoUpdaterChanged);
    onUpdateCheckTriggered = () => checkForUpdates(silent: false);

    hookServerService = HookServerService(
      onHookEvent: handleHookEvent,
      getStatusSnapshot: buildStatusSnapshotJson,
      onRemoteStatus: _applyRemoteStatusSnapshot,
    );

    desktopIntegration = DesktopIntegrationService(
      onSyncRequested: () => refreshAllUsage(),
      onReinstallHooksRequested: () => reinstallHooks(),
      onCheckUpdatesRequested: () => onUpdateCheckTriggered?.call(),
    );
  }

  final Map<String, TrafficLightState> _lastLight = {};

  /// Armed after the first real refresh, so seeded defaults never fire a "limit reached" toast at startup.
  bool _notifyArmed = false;

  /// Notifies when an agent turns red (limit hit) and when it leaves red (limit reset).
  void _notifyOnRedTransition() {
    for (final agent in [...allAgents, ...customStatuses]) {
      final now = agent.trafficLight;
      final before = _lastLight[agent.key];
      _lastLight[agent.key] = now;
      if (before == null || !_notifyArmed) continue;
      final wasRed = before == TrafficLightState.outOfUsage;
      final isRed = now == TrafficLightState.outOfUsage;
      if (isRed && !wasRed) {
        NotificationService.show(
            '${agent.title}: Limit erreicht', agent.effectiveSubtitle);
      } else if (wasRed && !isRed) {
        NotificationService.show(
            '${agent.title}: wieder verfügbar', 'Das Limit wurde zurückgesetzt.');
      }
    }
  }

  void _onAutoUpdaterChanged() {
    notifyListeners();
  }

  AgentStatusModel get codexStatus => _agents[AgentType.codex]!;
  AgentStatusModel get antigravityStatus => _agents[AgentType.antigravity]!;
  AgentStatusModel get claudeStatus => _agents[AgentType.claude]!;

  List<AgentStatusModel> get allAgents => [
        codexStatus,
        antigravityStatus,
        claudeStatus,
      ];

  List<AgentStatusModel> get customStatuses => _customStatus.values.toList();
  List<CustomAgent> get customAgents => List.unmodifiable(_customConfigs);

  bool get isRefreshing => _isRefreshing;
  bool get isAntigravityExpanded => _isAntigravityExpanded;
  bool get bindLanServer => _bindLanServer;
  String get remoteSyncHost => _remoteSyncHost;
  bool get remoteAccessEnabled => _remoteAccess;
  bool get pairedByCode => _joinSecret.isNotEmpty;

  /// Link inside the QR code: opens the web app, which pairs itself from the fragment.
  String get pairUrl => 'agentlights://pair/$_pairSecret';
  bool get demoMode => _demoMode;
  String get statusBannerMessage => _statusBannerMessage;
  bool get isHookServerRunning => hookServerService.isRunning;

  bool get updateAvailable => autoUpdaterService.updateAvailable;
  String get latestVersion => autoUpdaterService.latestVersion;
  String get currentVersion => autoUpdaterService.currentVersion;
  bool get isCheckingForUpdates => autoUpdaterService.isChecking;
  bool get isDownloadingUpdate => autoUpdaterService.isDownloading;
  double get updateDownloadProgress => autoUpdaterService.downloadProgress;
  String get updateStatusMessage => autoUpdaterService.statusMessage;

  Future<bool> checkForUpdates({bool silent = false}) =>
      autoUpdaterService.checkForUpdates(silent: silent);

  Future<bool> downloadAndInstallUpdate() =>
      autoUpdaterService.downloadAndInstallUpdate();

  void _initDefaultAgents() {
    final now = DateTime.now();
    final reset5h = now.add(const Duration(hours: 3, minutes: 24)).toUtc().toIso8601String();
    final resetWeek = now.add(const Duration(days: 4, hours: 11)).toUtc().toIso8601String();

    _agents[AgentType.codex] = AgentStatusModel(
      agentType: AgentType.codex,
      title: AgentType.codex.displayName,
      subtitle: 'Bereit (Idle)',
      rawHookState: TrafficLightState.idle,
      windows: [
        UsageWindow(
          key: 'five_hour',
          title: '5 Stunden',
          usedPercent: 28.0,
          resetsAt: reset5h,
        ),
        UsageWindow(
          key: 'seven_day',
          title: 'Woche',
          usedPercent: 41.0,
          resetsAt: resetWeek,
        ),
      ],
      authenticated: false,
      source: 'Codex · ChatGPT-Abo',
      lastUpdated: now,
    );

    final agWindows = [
      UsageWindow(
        key: 'gemini_five_hour',
        title: '5 Stunden',
        group: 'Gemini',
        usedPercent: 18.0,
        resetsAt: reset5h,
      ),
      UsageWindow(
        key: 'gemini_seven_day',
        title: 'Woche',
        group: 'Gemini',
        usedPercent: 12.0,
        resetsAt: resetWeek,
      ),
      UsageWindow(
        key: 'claude_gpt_five_hour',
        title: '5 Stunden',
        group: 'Claude / GPT',
        usedPercent: 36.0,
        resetsAt: reset5h,
      ),
      UsageWindow(
        key: 'claude_gpt_seven_day',
        title: 'Woche',
        group: 'Claude / GPT',
        usedPercent: 22.0,
        resetsAt: resetWeek,
      ),
    ];

    _agents[AgentType.antigravity] = AgentStatusModel(
      agentType: AgentType.antigravity,
      title: AgentType.antigravity.displayName,
      subtitle: 'Bereit (Idle)',
      rawHookState: TrafficLightState.idle,
      windows: agWindows,
      allAntigravitySubLimits: agWindows,
      authenticated: false,
      source: kAntigravitySource,
      lastUpdated: now,
    );

    _agents[AgentType.claude] = AgentStatusModel(
      agentType: AgentType.claude,
      title: AgentType.claude.displayName,
      subtitle: 'Bereit (Idle)',
      rawHookState: TrafficLightState.idle,
      windows: [
        UsageWindow(
          key: 'five_hour',
          title: '5 Stunden',
          usedPercent: 34.0,
          resetsAt: reset5h,
        ),
        UsageWindow(
          key: 'seven_day',
          title: 'Woche',
          usedPercent: 48.0,
          resetsAt: resetWeek,
        ),
      ],
      authenticated: false,
      source: 'Claude Code',
      lastUpdated: now,
    );
  }

  Future<void> initialize() async {
    await NotificationService.initialize();
    await desktopIntegration.initialize();
    unawaited(autoUpdaterService.initialize());

    try {
      final prefs = await SharedPreferences.getInstance();
      _bindLanServer = prefs.getBool('bind_lan_server') ?? false;
      _remoteSyncHost = prefs.getString('remote_sync_host') ?? '';
      _demoMode = prefs.getBool('demo_mode') ?? PlatformBridge.isWeb;
      _remoteAccess = prefs.getBool('remote_access') ?? false;
      _pairSecret = prefs.getString('pair_secret') ?? '';
      _joinSecret = prefs.getString('join_secret') ?? '';
      await _loadCustomAgents(prefs);
    } catch (_) {}

    // 1. Load cached `.tracker/usage.json` immediately for zero-latency startup
    final cached = await cacheService.load();
    _applyCachedStats(cached);

    // 2. Start local HTTP & WebSocket hook server on Desktop (`127.0.0.1:47832`)
    if (PlatformBridge.isDesktop) {
      await hookServerService.start(bindLan: _bindLanServer);
      final installRes = await hookInstallerService.ensureHooksInstalled();
      _applyHookInstallResult(installRes);
    } else if (_remoteSyncHost.isNotEmpty) {
      await hookServerService.connectToRemoteHost(_remoteSyncHost);
    }
    if (_joinSecret.isNotEmpty) {
      relay.startPolling(_joinSecret, _applyRemoteStatusSnapshot);
    }

    // 3. Perform live usage poll in background
    unawaited(refreshAllUsage());

    // 4. Start periodic timers (60s usage poll, 4s local file-activity watch)
    _usagePollTimer?.cancel();
    _usagePollTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => refreshAllUsage(),
    );

    if (PlatformBridge.isDesktop) {
      _activityWatchTimer?.cancel();
      _activityWatchTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _pollLocalFileActivity(),
      );
    }
  }

  void _applyCachedStats(Map<String, ProviderStats> cached) {
    var changed = false;
    final codexCached = cached['chatgpt'];
    if (codexCached != null) {
      _updateAgentWithProviderStats(AgentType.codex, codexCached);
      changed = true;
    }
    final agCached = cached['antigravity'];
    if (agCached != null) {
      _updateAgentWithProviderStats(AgentType.antigravity, agCached);
      changed = true;
    }
    final claudeCached = cached['claude'];
    if (claudeCached != null) {
      _updateAgentWithProviderStats(AgentType.claude, claudeCached);
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void _applyHookInstallResult(HookInstallResult res) {
    for (final type in _agents.keys.toList()) {
      _agents[type] = _agents[type]!.copyWith(
        hookInstalled: res.isInstalledFor(type),
      );
    }
    notifyListeners();
  }

  /// Processes a real-time hook event from `POST /api/hook` or WebSocket in <1ms.
  void handleHookEvent(HookEventPayload event) {
    final current = event.agent == AgentType.custom
        ? _customStatus[event.customId]
        : _agents[event.agent];
    if (current == null) return;

    final windows = current.agentType == AgentType.custom && event.usage.isNotEmpty
        ? [
            for (final w in current.windows)
              event.usage.containsKey(w.key)
                  ? UsageWindow(key: w.key, title: w.title, usedPercent: event.usage[w.key])
                  : w,
          ]
        : null;
    _put(current.copyWith(
      windows: windows,
      rawHookState: event.targetState,
      hasErrorHook: event.isErrorEvent,
      subtitle: event.detail,
      lastUpdated: event.timestamp,
      lastHookActivity: event.timestamp,
    ));
    notifyListeners();
    hookServerService.broadcast(buildStatusSnapshotJson());

    if (event.shouldRefreshUsage && event.agent != AgentType.custom) {
      unawaited(refreshAgentUsage(event.agent));
    }
  }

  Future<void> _pollLocalFileActivity() async {
    if (_demoMode || !PlatformBridge.isDesktop) return;
    final now = DateTime.now();
    var anyChanged = false;

    // 1. Check Claude Code JSONL telemetry
    final claudeCurrent = _agents[AgentType.claude]!;
    final claudeHookAge = claudeCurrent.lastHookActivity != null
        ? now.difference(claudeCurrent.lastHookActivity!)
        : const Duration(hours: 1);
    if (claudeHookAge > const Duration(seconds: 6)) {
      final signal = await claudeService.checkLiveJsonlSignal();
      // A file that was just written must not hide a pending permission prompt (yellow).
      final keepYellow = claudeCurrent.rawHookState == TrafficLightState.needsInput &&
          signal?.state == TrafficLightState.working;
      if (signal != null && !keepYellow) {
        if (claudeCurrent.rawHookState != signal.state ||
            claudeCurrent.subtitle != signal.detail) {
          _agents[AgentType.claude] = claudeCurrent.copyWith(
            rawHookState: signal.state,
            hasErrorHook: signal.hasError,
            subtitle: signal.detail,
            lastUpdated: now,
          );
          anyChanged = true;
        }
      } else if (claudeCurrent.rawHookState == TrafficLightState.working &&
          claudeHookAge > const Duration(seconds: 15)) {
        _agents[AgentType.claude] = claudeCurrent.copyWith(
          rawHookState: TrafficLightState.idle,
          subtitle: 'Bereit (Idle)',
          lastUpdated: now,
        );
        anyChanged = true;
      }
    }

    // 2. Check Codex session JSONL activity
    final codexCurrent = _agents[AgentType.codex]!;
    final codexHookAge = codexCurrent.lastHookActivity != null
        ? now.difference(codexCurrent.lastHookActivity!)
        : const Duration(hours: 1);
    if (codexHookAge > const Duration(seconds: 6)) {
      final snap = await codexService.checkLiveActivity();
      if (snap.hasRateLimitError) {
        if (!codexCurrent.hasErrorHook) {
          _agents[AgentType.codex] = codexCurrent.copyWith(
            rawHookState: TrafficLightState.outOfUsage,
            hasErrorHook: true,
            subtitle: snap.latestDetail ?? 'Rate-Limit erreicht',
            lastUpdated: now,
          );
          anyChanged = true;
        }
      } else if (snap.isRecentlyWorking) {
        if (codexCurrent.rawHookState != TrafficLightState.working) {
          _agents[AgentType.codex] = codexCurrent.copyWith(
            rawHookState: TrafficLightState.working,
            subtitle: snap.latestDetail ?? 'Codex arbeitet...',
            lastUpdated: now,
          );
          anyChanged = true;
        }
      } else if (codexCurrent.rawHookState == TrafficLightState.working &&
          codexHookAge > const Duration(seconds: 15)) {
        _agents[AgentType.codex] = codexCurrent.copyWith(
          rawHookState: TrafficLightState.idle,
          subtitle: 'Bereit (Idle)',
          lastUpdated: now,
        );
        anyChanged = true;
      }
    }

    // 3. Check Antigravity brain file activity
    final agCurrent = _agents[AgentType.antigravity]!;
    final agHookAge = agCurrent.lastHookActivity != null
        ? now.difference(agCurrent.lastHookActivity!)
        : const Duration(hours: 1);
    if (agHookAge > const Duration(seconds: 6)) {
      final isAgActive = await antigravityService.hasRecentFileActivity();
      if (isAgActive && agCurrent.rawHookState != TrafficLightState.working) {
        _agents[AgentType.antigravity] = agCurrent.copyWith(
          rawHookState: TrafficLightState.working,
          subtitle: 'Antigravity Agent aktiv...',
          lastUpdated: now,
        );
        anyChanged = true;
      } else if (!isAgActive &&
          agCurrent.rawHookState == TrafficLightState.working &&
          agHookAge > const Duration(seconds: 15)) {
        _agents[AgentType.antigravity] = agCurrent.copyWith(
          rawHookState: TrafficLightState.idle,
          subtitle: 'Bereit (Idle)',
          lastUpdated: now,
        );
        anyChanged = true;
      }
    }

    if (anyChanged) {
      notifyListeners();
      hookServerService.broadcast(buildStatusSnapshotJson());
    }
  }

  Future<void> refreshAllUsage() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    notifyListeners();

    try {
      if (_demoMode) {
        _populateDemoUsage();
        return;
      }
      if (!PlatformBridge.isDesktop) {
        return;
      }
      final cached = await cacheService.load();

      await Future.wait([
        refreshAgentUsage(AgentType.codex, cachedStats: cached['chatgpt']),
        refreshAgentUsage(
          AgentType.antigravity,
          cachedStats: cached['antigravity'],
        ),
        refreshAgentUsage(AgentType.claude, cachedStats: cached['claude']),
      ]);
      hookServerService.broadcast(buildStatusSnapshotJson());
    } finally {
      _isRefreshing = false;
      notifyListeners(); // records the baseline silently on the first refresh
      _notifyArmed = true;
    }
  }

  Future<void> refreshAgentUsage(
    AgentType type, {
    ProviderStats? cachedStats,
  }) async {
    if (!PlatformBridge.isDesktop) return;
    try {
      ProviderStats stats;
      switch (type) {
        case AgentType.codex:
          stats = await codexService.check();
          break;
        case AgentType.antigravity:
          stats = await antigravityService.check();
          break;
        case AgentType.claude:
          stats = await claudeService.check(cachedStats: cachedStats);
          break;
        case AgentType.custom:
          return; // custom agents report via hooks only
      }

      // Token-only windows (Claude without a live plan limit) carry a label but no percentage.
      final hasMeasured = stats.windows
          .any((w) => w.usedPercent != null || w.customQuotaLabel != null);
      if (hasMeasured && stats.authenticated) {
        await cacheService.put(type.cacheProviderId, stats);
        _updateAgentWithProviderStats(type, stats);
      } else if (cachedStats != null &&
          cachedStats.windows.any((w) => w.usedPercent != null)) {
        _updateAgentWithProviderStats(type, cachedStats);
      } else if (hasMeasured) {
        _updateAgentWithProviderStats(type, stats);
      } else {
        // Keep existing display rings if live check is paused/unverified, but update detail & source
        final current = _agents[type]!;
        _agents[type] = current.copyWith(
          detail: stats.detail,
          source: stats.source,
          // Rings that stay on screen without a fresh measurement are old numbers: say so.
          stale: current.windows.any((w) => w.usedPercent != null),
        );
      }
      notifyListeners();
    } catch (_) {}
  }

  void _updateAgentWithProviderStats(AgentType type, ProviderStats stats) {
    final current = _agents[type]!;
    final subLimits = stats.subLimits.isNotEmpty
        ? stats.subLimits
        : List<UsageWindow>.from(stats.windows);
    _agents[type] = current.copyWith(
      windows: stats.windows,
      allAntigravitySubLimits:
          type == AgentType.antigravity ? subLimits : current.allAntigravitySubLimits,
      authenticated: stats.authenticated,
      stale: stats.stale,
      source: stats.source,
      detail: stats.detail,
      lastUpdated: DateTime.now(),
    );
  }

  void _populateDemoUsage() {
    final now = DateTime.now();
    final reset5h =
        now.add(const Duration(hours: 2, minutes: 15)).toUtc().toIso8601String();
    final resetWeek =
        now.add(const Duration(days: 4, hours: 8)).toUtc().toIso8601String();

    _agents[AgentType.codex] = _agents[AgentType.codex]!.copyWith(
      rawHookState: TrafficLightState.working,
      subtitle: 'Führt Bash-Tool aus...',
      authenticated: true,
      source: 'Codex · ChatGPT-Abo · Plus',
      windows: [
        UsageWindow(
          key: 'five_hour',
          title: '5 Stunden',
          usedPercent: 28.0,
          resetsAt: reset5h,
        ),
        UsageWindow(
          key: 'seven_day',
          title: 'Woche',
          usedPercent: 54.0,
          resetsAt: resetWeek,
        ),
      ],
      lastUpdated: now,
    );

    final agSubLimits = [
      UsageWindow(
        key: 'gemini_five_hour',
        title: '5 Stunden',
        group: 'Gemini',
        usedPercent: 18.0,
        resetsAt: reset5h,
      ),
      UsageWindow(
        key: 'gemini_seven_day',
        title: 'Woche',
        group: 'Gemini',
        usedPercent: 11.0,
        resetsAt: resetWeek,
      ),
      UsageWindow(
        key: 'claude_gpt_five_hour',
        title: '5 Stunden',
        group: 'Claude / GPT',
        usedPercent: 92.0,
        resetsAt: reset5h,
      ),
      UsageWindow(
        key: 'claude_gpt_seven_day',
        title: 'Woche',
        group: 'Claude / GPT',
        usedPercent: 45.0,
        resetsAt: resetWeek,
      ),
      UsageWindow(
        key: 'model_gemini_pro',
        title: '5 Stunden',
        group: 'Gemini 2.5 Pro',
        usedPercent: 24.0,
        resetsAt: reset5h,
      ),
      UsageWindow(
        key: 'model_claude_sonnet',
        title: '5 Stunden',
        group: 'Claude Sonnet',
        usedPercent: 92.0,
        resetsAt: reset5h,
      ),
    ];

    _agents[AgentType.antigravity] = _agents[AgentType.antigravity]!.copyWith(
      rawHookState: TrafficLightState.needsInput,
      subtitle: 'Wartet auf Freigabe',
      authenticated: true,
      source: kAntigravitySource,
      windows: agSubLimits.take(4).toList(),
      allAntigravitySubLimits: agSubLimits,
      lastUpdated: now,
    );

    _agents[AgentType.claude] = _agents[AgentType.claude]!.copyWith(
      rawHookState: TrafficLightState.idle,
      subtitle: 'Bereit (Idle)',
      authenticated: true,
      source: 'Claude Code · Max',
      windows: [
        UsageWindow(
          key: 'five_hour',
          title: '5 Stunden',
          usedPercent: 36.0,
          resetsAt: reset5h,
          customQuotaLabel: '162k / 450k',
        ),
        UsageWindow(
          key: 'seven_day',
          title: 'Woche',
          usedPercent: 61.0,
          resetsAt: resetWeek,
          customQuotaLabel: '1.9M / 3.2M',
        ),
      ],
      lastUpdated: now,
    );
    notifyListeners();
  }

  /// Cycles an agent's traffic light state on click or during interactive testing.
  void cycleAgentTrafficLight(AgentType type, {String? customId}) {
    final current = (customId != null ? _customStatus[customId] : _agents[type])!;
    TrafficLightState next;
    bool errorHook = false;
    switch (current.trafficLight) {
      case TrafficLightState.idle:
        next = TrafficLightState.working;
        break;
      case TrafficLightState.working:
        next = TrafficLightState.needsInput;
        break;
      case TrafficLightState.needsInput:
        next = TrafficLightState.outOfUsage;
        errorHook = true;
        break;
      case TrafficLightState.outOfUsage:
        next = TrafficLightState.idle;
        errorHook = false;
        break;
    }
    _put(current.copyWith(
      rawHookState: next,
      hasErrorHook: errorHook,
      subtitle: next.defaultSubtitle,
      lastUpdated: DateTime.now(),
      lastHookActivity: DateTime.now(),
    ));
    notifyListeners();
    hookServerService.broadcast(buildStatusSnapshotJson());
  }

  Future<void> toggleAntigravityExpanded() async {
    _isAntigravityExpanded = !_isAntigravityExpanded;
    notifyListeners();
    await desktopIntegration.setHudExpanded(_isAntigravityExpanded);
  }

  Future<HookInstallResult> reinstallHooks() async {
    final res = await hookInstallerService.ensureHooksInstalled();
    _applyHookInstallResult(res);
    _statusBannerMessage = res.updatedFiles.isNotEmpty
        ? 'Hooks erfolgreich aktualisiert (${res.updatedFiles.length} Dateien, .bak gesichert).'
        : 'Hook-Konfiguration geprüft.';
    notifyListeners();
    return res;
  }

  Future<void> setBindLanServer(bool enabled) async {
    _bindLanServer = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bind_lan_server', enabled);
    } catch (_) {}
    if (PlatformBridge.isDesktop) {
      await hookServerService.start(bindLan: enabled);
    }
    notifyListeners();
  }

  Future<void> setRemoteSyncHost(String host) async {
    _remoteSyncHost = host.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('remote_sync_host', _remoteSyncHost);
    } catch (_) {}
    if (_remoteSyncHost.isNotEmpty) {
      await hookServerService.connectToRemoteHost(_remoteSyncHost);
    } else {
      await hookServerService.disconnectRemoteHost();
    }
    notifyListeners();
  }

  /// Pairs this phone/web app with a desktop from a scanned link, `pair=SECRET` or the bare code.
  Future<bool> joinWithCode(String input) async {
    final secret = RelaySyncService.parseSecret(input);
    if (secret == null) return false;
    _joinSecret = secret;
    _demoMode = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('join_secret', secret);
      await prefs.setBool('demo_mode', false);
    } catch (_) {}
    relay.startPolling(secret, _applyRemoteStatusSnapshot);
    notifyListeners();
    return true;
  }

  Future<void> leaveRemote() async {
    _joinSecret = '';
    relay.stop();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('join_secret');
    } catch (_) {}
    notifyListeners();
  }

  /// Desktop: starts or stops publishing the status for paired phones. [renew] makes a new code and
  /// thereby cuts off every phone that used the old one.
  Future<void> setRemoteAccess(bool enabled, {bool renew = false}) async {
    _remoteAccess = enabled;
    if (enabled && (_pairSecret.isEmpty || renew)) _pairSecret = RelaySyncService.newSecret();
    _lastRelayBody = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('remote_access', enabled);
      await prefs.setString('pair_secret', _pairSecret);
    } catch (_) {}
    notifyListeners();
    if (enabled) unawaited(_publishRelay());
  }

  void _scheduleRelayPublish() {
    if (!_remoteAccess || !PlatformBridge.isDesktop || _pairSecret.isEmpty) return;
    if (_relayTimer?.isActive ?? false) return;
    _relayTimer = Timer(const Duration(seconds: 3), _publishRelay);
  }

  /// Snapshot without the bulky per-model lists so it fits one message.
  String _compactSnapshotBody() {
    var snap = buildStatusSnapshotJson();
    var body = jsonEncode(snap);
    if (utf8.encode(body).length > RelaySyncService.maxBodyBytes) {
      snap = {
        ...snap,
        'agents': {
          for (final e in (snap['agents'] as Map).entries)
            e.key: {
              for (final f in (e.value as Map).entries)
                if (f.key != 'all_antigravity_sub_limits') f.key: f.value,
            },
        },
      };
      body = jsonEncode(snap);
    }
    return body;
  }

  Future<void> _publishRelay() async {
    if (!_remoteAccess || _pairSecret.isEmpty) return;
    final body = _compactSnapshotBody();
    // Changes only (ignoring the timestamp), at most once a minute (ntfy.sh allows 250 messages per 12 h), plus a heartbeat every 10 minutes.
    final stripped = body.replaceAll(RegExp(r'"timestamp":"[^"]*"'), '');
    final now = DateTime.now();
    final since = now.difference(_lastRelayPublish);
    if (stripped == _lastRelayBody && since < const Duration(minutes: 10)) return;
    if (since < const Duration(seconds: 60)) {
      _relayTimer = Timer(const Duration(seconds: 60) - since, _publishRelay);
      return;
    }
    if (await relay.publish(_pairSecret, body)) {
      _lastRelayBody = stripped;
      _lastRelayPublish = now;
    }
  }

  Future<void> setDemoMode(bool enabled) async {
    _demoMode = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('demo_mode', enabled);
    } catch (_) {}
    if (enabled) {
      _populateDemoUsage();
    } else {
      await refreshAllUsage();
    }
    notifyListeners();
  }

  Map<String, dynamic> buildStatusSnapshotJson() {
    return {
      'version': 1,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'agents': {
        for (final entry in _agents.entries)
          entry.key.id: entry.value.toJson(),
        for (final s in _customStatus.values) s.key: s.toJson(),
      },
    };
  }

  void _applyRemoteStatusSnapshot(Map<String, dynamic> snapshot) {
    final agentsMap = snapshot['agents'];
    if (agentsMap is! Map) return;
    var updated = false;
    for (final entry in agentsMap.entries) {
      if (entry.key.toString().startsWith('custom:') && entry.value is Map) {
        final m = AgentStatusModel.fromJson(Map<String, dynamic>.from(entry.value as Map));
        if (m.customId != null) {
          _customStatus[m.customId!] = m;
          updated = true;
        }
        continue;
      }
      final type = AgentType.fromString(entry.key.toString());
      if (type != null && entry.value is Map) {
        _agents[type] = AgentStatusModel.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        updated = true;
      }
    }
    if (updated) {
      notifyListeners();
    }
  }

  void _put(AgentStatusModel m) {
    if (m.customId != null) {
      _customStatus[m.customId!] = m;
    } else {
      _agents[m.agentType] = m;
    }
  }

  AgentStatusModel _customModel(CustomAgent c, {AgentStatusModel? old}) =>
      AgentStatusModel(
        agentType: AgentType.custom,
        title: c.name,
        subtitle: old?.subtitle ?? 'Bereit (Idle)',
        rawHookState: old?.rawHookState ?? TrafficLightState.idle,
        hasErrorHook: old?.hasErrorHook ?? false,
        windows: c.windows,
        source: 'Eigener Agent · Hook',
        lastUpdated: DateTime.now(),
        lastHookActivity: old?.lastHookActivity,
        customId: c.id,
        customColor: c.color,
      );

  Future<void> _loadCustomAgents(SharedPreferences prefs) async {
    _customConfigs = CustomAgent.decodeList(prefs.getString('custom_agents'));
    for (final c in _customConfigs) {
      _customStatus[c.id] = _customModel(c);
    }
  }

  /// Adds or replaces (same id) a user-defined agent and persists the list.
  Future<void> saveCustomAgent(CustomAgent agent) async {
    _customConfigs = [
      for (final c in _customConfigs)
        if (c.id != agent.id) c,
      agent,
    ];
    _customStatus[agent.id] = _customModel(agent, old: _customStatus[agent.id]);
    await _persistCustomAgents();
    notifyListeners();
  }

  Future<void> removeCustomAgent(String id) async {
    _customConfigs = _customConfigs.where((c) => c.id != id).toList();
    _customStatus.remove(id);
    _lastLight.remove('custom:$id');
    await _persistCustomAgents();
    notifyListeners();
  }

  Future<void> _persistCustomAgents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('custom_agents', CustomAgent.encodeList(_customConfigs));
    } catch (_) {}
  }

  @override
  void dispose() {
    _usagePollTimer?.cancel();
    _activityWatchTimer?.cancel();
    _relayTimer?.cancel();
    relay.stop();
    autoUpdaterService.removeListener(_onAutoUpdaterChanged);
    autoUpdaterService.dispose();
    unawaited(hookServerService.stop());
    super.dispose();
  }
}
