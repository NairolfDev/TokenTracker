import 'package:flutter/material.dart';
import 'app_constants.dart';
import 'usage_window.dart';

enum AgentType {
  codex,
  antigravity,
  claude,

  /// User-defined agent; identity lives in AgentStatusModel.customId.
  custom;

  String get id {
    switch (this) {
      case AgentType.codex:
        return 'codex';
      case AgentType.antigravity:
        return 'antigravity';
      case AgentType.claude:
        return 'claude';
      case AgentType.custom:
        return 'custom';
    }
  }

  String get cacheProviderId {
    switch (this) {
      case AgentType.codex:
        return 'chatgpt';
      case AgentType.antigravity:
        return 'antigravity';
      case AgentType.claude:
        return 'claude';
      case AgentType.custom:
        return 'custom';
    }
  }

  String get displayName {
    switch (this) {
      case AgentType.codex:
        return 'OpenAI Codex';
      case AgentType.antigravity:
        return 'Google Antigravity';
      case AgentType.claude:
        return 'Claude Code';
      case AgentType.custom:
        return 'Eigener Agent';
    }
  }

  String get monogram {
    switch (this) {
      case AgentType.codex:
        return 'CX';
      case AgentType.antigravity:
        return 'AG';
      case AgentType.claude:
        return 'CC';
      case AgentType.custom:
        return 'AI';
    }
  }

  Color get brandColor {
    switch (this) {
      case AgentType.codex:
        return AppConstants.accentCodex;
      case AgentType.antigravity:
        return AppConstants.accentAntigravity;
      case AgentType.claude:
        return AppConstants.accentClaude;
      case AgentType.custom:
        return const Color(0xFF94A3B8);
    }
  }

  static AgentType? fromString(String? raw) {
    if (raw == null) return null;
    final clean = raw.trim().toLowerCase();
    if (clean == 'codex' || clean == 'chatgpt' || clean == 'openai') {
      return AgentType.codex;
    }
    if (clean == 'antigravity' || clean == 'gemini') {
      return AgentType.antigravity;
    }
    if (clean == 'claude' || clean == 'anthropic') {
      return AgentType.claude;
    }
    return null;
  }
}

/// 4-Chamber Traffic Light States (Top to Bottom: Red, Yellow, Green, White).
enum TrafficLightState {
  /// Chamber 1 (Top): RED (#FF2A2A) - Out of Usage (0% remaining) or Hard Rate-Limit / API Error.
  outOfUsage,

  /// Chamber 2: YELLOW (#FFB800) - Waiting for user input or tool permission.
  needsInput,

  /// Chamber 3: GREEN (#00E676) - Actively working / executing tools / thinking.
  working,

  /// Chamber 4 (Bottom): WHITE (#F8FAFC) - Idle / Task finished.
  idle;

  int get chamberIndex {
    switch (this) {
      case TrafficLightState.outOfUsage:
        return 0;
      case TrafficLightState.needsInput:
        return 1;
      case TrafficLightState.working:
        return 2;
      case TrafficLightState.idle:
        return 3;
    }
  }

  Color get color {
    switch (this) {
      case TrafficLightState.outOfUsage:
        return AppConstants.ampelRed;
      case TrafficLightState.needsInput:
        return AppConstants.ampelYellow;
      case TrafficLightState.working:
        return AppConstants.ampelGreen;
      case TrafficLightState.idle:
        return AppConstants.ampelWhite;
    }
  }

  String get defaultSubtitle {
    switch (this) {
      case TrafficLightState.outOfUsage:
        return 'Limit erreicht · Gesperrt';
      case TrafficLightState.needsInput:
        return 'Wartet auf Freigabe';
      case TrafficLightState.working:
        return 'Arbeitet...';
      case TrafficLightState.idle:
        return 'Bereit (Idle)';
    }
  }

  static TrafficLightState fromString(String? raw) {
    switch (raw?.toLowerCase().trim()) {
      case 'outofusage':
      case 'out_of_usage':
      case 'error':
      case 'red':
        return TrafficLightState.outOfUsage;
      case 'needsinput':
      case 'needs_input':
      case 'permission':
      case 'yellow':
        return TrafficLightState.needsInput;
      case 'working':
      case 'start':
      case 'green':
        return TrafficLightState.working;
      case 'idle':
      case 'stop':
      case 'white':
      default:
        return TrafficLightState.idle;
    }
  }
}

class AgentStatusModel {
  final AgentType agentType;
  final String title;
  final String subtitle;
  final TrafficLightState rawHookState;
  final bool hasErrorHook;
  final List<UsageWindow> windows;
  final List<UsageWindow> allAntigravitySubLimits;
  final bool authenticated;
  final bool stale;
  final String source;
  final String detail;
  final DateTime lastUpdated;
  final DateTime? lastHookActivity;
  final bool hookInstalled;
  final String? customId;
  final Color? customColor;

  const AgentStatusModel({
    required this.agentType,
    required this.title,
    required this.subtitle,
    this.rawHookState = TrafficLightState.idle,
    this.hasErrorHook = false,
    this.windows = const [],
    this.allAntigravitySubLimits = const [],
    this.authenticated = false,
    this.stale = false,
    this.source = '',
    this.detail = '',
    required this.lastUpdated,
    this.lastHookActivity,
    this.hookInstalled = false,
    this.customId,
    this.customColor,
  });

  /// Stable key across built-in and custom agents.
  String get key => customId != null ? 'custom:$customId' : agentType.id;
  Color get accent => customColor ?? agentType.brandColor;
  String get monogram => agentType == AgentType.custom
      ? (title.trim().isEmpty ? 'AI' : title.trim().substring(0, title.trim().length < 2 ? 1 : 2).toUpperCase())
      : agentType.monogram;

  /// Returns true if any active usage window is exhausted (0% remaining / 100% used).
  bool get hasExhaustedWindow {
    // Windows with a customQuotaLabel are local token estimates against guessed caps: shown, but never red.
    final activeWindows = windows.where(
      (w) => !w.disabled && w.usedPercent != null && w.customQuotaLabel == null,
    );
    if (activeWindows.any((w) => w.isExhausted)) return true;
    if (agentType == AgentType.antigravity) {
      return allAntigravitySubLimits
          .where((w) => !w.disabled && w.usedPercent != null)
          .any((w) => w.isExhausted);
    }
    return false;
  }

  /// Evaluates the effective 4-Chamber Traffic Light state:
  /// Chamber 1 (RED) always takes priority if any limit is at 0% remaining OR an error/rate-limit hook occurred.
  TrafficLightState get trafficLight {
    if (hasExhaustedWindow || hasErrorHook || rawHookState == TrafficLightState.outOfUsage) {
      return TrafficLightState.outOfUsage;
    }
    return rawHookState;
  }

  /// Effective status text shown below the agent name.
  String get effectiveSubtitle {
    if (trafficLight == TrafficLightState.outOfUsage) {
      if (hasExhaustedWindow) {
        return 'Quota erschöpft (0% übrig)';
      }
      if (subtitle.isNotEmpty && subtitle != 'Bereit (Idle)') {
        return subtitle;
      }
      return TrafficLightState.outOfUsage.defaultSubtitle;
    }
    final base = subtitle.isNotEmpty ? subtitle : trafficLight.defaultSubtitle;
    if (stale && trafficLight == TrafficLightState.idle && agentType != AgentType.custom) {
      return 'Bereit · Zahlen veraltet (Dienst nicht erreichbar)';
    }
    if (tokenOnly && trafficLight == TrafficLightState.idle) {
      final tokens = windows
          .map((w) => '${w.customQuotaLabel?.replaceAll(' Tokens', '')} ${w.shortLabel}')
          .join(' · ');
      return 'Limit unbekannt (nicht angemeldet) · $tokens';
    }
    return base;
  }

  /// Claude without a signed-in limit source: only locally counted tokens, no percentages.
  bool get tokenOnly =>
      agentType == AgentType.claude &&
      windows.isNotEmpty &&
      windows.every((w) => w.usedPercent == null);

  /// Primary Usage Windows shown in Zone 3 of the compact card:
  /// - For Codex and Claude: up to 3 rings (`5h`, `Week`, `Month` if available).
  /// - For Antigravity in collapsed mode: the tightest ring (lowest `remainingFraction`) + the second most important ring.
  List<UsageWindow> get primaryWindows {
    if (tokenOnly) return const [];
    if (agentType != AgentType.antigravity) {
      return windows.take(3).toList();
    }
    final candidates = allAntigravitySubLimits.isNotEmpty
        ? List<UsageWindow>.from(allAntigravitySubLimits)
        : List<UsageWindow>.from(windows);
    if (candidates.isEmpty) return const [];
    if (candidates.length <= 2) return candidates;

    // Sort measured windows by lowest remainingFraction first (tightest bottleneck first).
    final measured = candidates
        .where((w) => !w.disabled && w.usedPercent != null)
        .toList()
      ..sort((a, b) => a.remainingFraction.compareTo(b.remainingFraction));

    if (measured.length >= 2) {
      final first = measured[0];
      // Prefer a window from a different model group if available so both Gemini & Claude/GPT are represented,
      // otherwise pick the second tightest window.
      final diffGroup = measured.skip(1).where((w) => w.group != first.group).toList();
      final second = diffGroup.isNotEmpty ? diffGroup.first : measured[1];
      return [first, second];
    }
    if (measured.length == 1) {
      final first = measured.first;
      final other = candidates.firstWhere((w) => w.key != first.key, orElse: () => candidates[1]);
      return [first, other];
    }
    return candidates.take(2).toList();
  }

  AgentStatusModel copyWith({
    AgentType? agentType,
    String? title,
    String? subtitle,
    TrafficLightState? rawHookState,
    bool? hasErrorHook,
    List<UsageWindow>? windows,
    List<UsageWindow>? allAntigravitySubLimits,
    bool? authenticated,
    bool? stale,
    String? source,
    String? detail,
    DateTime? lastUpdated,
    DateTime? lastHookActivity,
    bool? hookInstalled,
  }) {
    return AgentStatusModel(
      agentType: agentType ?? this.agentType,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      rawHookState: rawHookState ?? this.rawHookState,
      hasErrorHook: hasErrorHook ?? this.hasErrorHook,
      windows: windows ?? this.windows,
      allAntigravitySubLimits:
          allAntigravitySubLimits ?? this.allAntigravitySubLimits,
      authenticated: authenticated ?? this.authenticated,
      stale: stale ?? this.stale,
      source: source ?? this.source,
      detail: detail ?? this.detail,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      lastHookActivity: lastHookActivity ?? this.lastHookActivity,
      hookInstalled: hookInstalled ?? this.hookInstalled,
      customId: customId,
      customColor: customColor,
    );
  }

  Map<String, dynamic> toJson() => {
        'agent_type': agentType.id,
        'title': title,
        'subtitle': effectiveSubtitle,
        'traffic_light': trafficLight.name,
        'raw_hook_state': rawHookState.name,
        'has_error_hook': hasErrorHook,
        'windows': windows.map((w) => w.toJson()).toList(),
        'primary_windows': primaryWindows.map((w) => w.toJson()).toList(),
        'all_antigravity_sub_limits':
            allAntigravitySubLimits.map((w) => w.toJson()).toList(),
        'authenticated': authenticated,
        'stale': stale,
        'source': source,
        'detail': detail,
        'last_updated': lastUpdated.toUtc().toIso8601String(),
        'last_hook_activity': lastHookActivity?.toUtc().toIso8601String(),
        'hook_installed': hookInstalled,
        if (customId != null) 'custom_id': customId,
        if (customColor != null) 'custom_color': customColor!.toARGB32(),
      };

  factory AgentStatusModel.fromJson(Map<String, dynamic> json) {
    final customId = json['custom_id']?.toString();
    final type = customId != null
        ? AgentType.custom
        : (AgentType.fromString(json['agent_type']?.toString()) ?? AgentType.codex);
    final rawWindows = (json['windows'] as List?)
            ?.whereType<Map>()
            .map((m) => UsageWindow.fromJson(Map<String, dynamic>.from(m)))
            .toList() ??
        const <UsageWindow>[];
    final rawSubLimits = (json['all_antigravity_sub_limits'] as List?)
            ?.whereType<Map>()
            .map((m) => UsageWindow.fromJson(Map<String, dynamic>.from(m)))
            .toList() ??
        const <UsageWindow>[];

    return AgentStatusModel(
      agentType: type,
      title: json['title']?.toString() ?? type.displayName,
      subtitle: json['subtitle']?.toString() ?? 'Bereit (Idle)',
      rawHookState: TrafficLightState.fromString(
        json['raw_hook_state']?.toString() ?? json['traffic_light']?.toString(),
      ),
      hasErrorHook: json['has_error_hook'] == true,
      windows: rawWindows,
      allAntigravitySubLimits: rawSubLimits,
      authenticated: json['authenticated'] == true,
      stale: json['stale'] == true,
      source: json['source']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
      lastUpdated: DateTime.tryParse(json['last_updated']?.toString() ?? '') ??
          DateTime.now(),
      lastHookActivity: json['last_hook_activity'] != null
          ? DateTime.tryParse(json['last_hook_activity'].toString())
          : null,
      hookInstalled: json['hook_installed'] == true,
      customId: customId,
      customColor: json['custom_color'] is num
          ? Color((json['custom_color'] as num).toInt())
          : null,
    );
  }
}
