import '../models/agent_status.dart';
import '../models/custom_agent.dart';
import '../models/usage_window.dart';

class HookEventPayload {
  final AgentType agent;
  final String? customId;

  /// Optional used-percent per limit label/key from the hook (`"usage": {"5h": 40}`).
  final Map<String, double> usage;
  final TrafficLightState targetState;
  final bool isErrorEvent;
  final bool shouldRefreshUsage;
  final String detail;
  final DateTime timestamp;

  const HookEventPayload({
    required this.agent,
    this.customId,
    this.usage = const {},
    required this.targetState,
    required this.isErrorEvent,
    required this.shouldRefreshUsage,
    required this.detail,
    required this.timestamp,
  });

  /// Parses an incoming hook JSON map from `POST /api/hook` in <1ms.
  static HookEventPayload? parse(Map<String, dynamic> json) {
    final agentRaw =
        json['agent']?.toString() ?? json['provider']?.toString() ?? '';
    final builtIn = AgentType.fromString(agentRaw);
    final customId = builtIn == null ? CustomAgent.slug(agentRaw) : null;
    if (builtIn == null && customId!.isEmpty) return null;
    final agent = builtIn ?? AgentType.custom;
    final usage = <String, double>{};
    final rawUsage = json['usage'];
    if (rawUsage is Map) {
      rawUsage.forEach((k, v) {
        final p = parsePercent(v);
        if (p != null) usage[CustomAgent.slug(k.toString())] = p;
      });
    }

    final eventRaw = (json['event']?.toString() ??
            json['hook_event_name']?.toString() ??
            'working')
        .trim()
        .toLowerCase();
    final detailRaw = (json['detail']?.toString() ??
            json['message']?.toString() ??
            json['tool_name']?.toString() ??
            '')
        .trim();
    final combinedLower = '$eventRaw $detailRaw ${json['error'] ?? ''}'
        .toLowerCase();

    final hasRateLimitError = eventRaw == 'error' ||
        combinedLower.contains('429') ||
        combinedLower.contains('quota_exceeded') ||
        combinedLower.contains('overloaded') ||
        combinedLower.contains('usage limit') ||
        combinedLower.contains('rate_limit') ||
        combinedLower.contains('exhausted');

    if (hasRateLimitError) {
      return HookEventPayload(
        agent: agent,
        customId: customId,
        usage: usage,
        targetState: TrafficLightState.outOfUsage,
        isErrorEvent: true,
        shouldRefreshUsage: true,
        detail: detailRaw.isNotEmpty
            ? detailRaw
            : 'Rate-Limit / Quota erschöpft',
        timestamp: DateTime.now(),
      );
    }

    if (eventRaw == 'permission' ||
        eventRaw == 'permission_prompt' ||
        eventRaw == 'permissionrequest' ||
        eventRaw == 'ask_user' ||
        eventRaw == 'notification' &&
            combinedLower.contains('permission')) {
      return HookEventPayload(
        agent: agent,
        customId: customId,
        usage: usage,
        targetState: TrafficLightState.needsInput,
        isErrorEvent: false,
        shouldRefreshUsage: false,
        detail: detailRaw.isNotEmpty ? detailRaw : 'Wartet auf Freigabe',
        timestamp: DateTime.now(),
      );
    }

    if (eventRaw == 'stop' ||
        eventRaw == 'sessionend' ||
        eventRaw == 'afteragent' ||
        eventRaw == 'idle') {
      return HookEventPayload(
        agent: agent,
        customId: customId,
        usage: usage,
        targetState: TrafficLightState.idle,
        isErrorEvent: false,
        shouldRefreshUsage: true,
        detail: detailRaw.isNotEmpty ? detailRaw : 'Bereit (Idle)',
        timestamp: DateTime.now(),
      );
    }

    // Default active states: `start`, `working`, `sessionstart`, `pretooluse`, `posttooluse`, `beforetool`
    return HookEventPayload(
      agent: agent,
      customId: customId,
      usage: usage,
      targetState: TrafficLightState.working,
      isErrorEvent: false,
      shouldRefreshUsage: false,
      detail: detailRaw.isNotEmpty ? detailRaw : 'Führt Aufgabe aus...',
      timestamp: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'agent': agent.id,
        'target_state': targetState.name,
        'is_error_event': isErrorEvent,
        'should_refresh_usage': shouldRefreshUsage,
        'detail': detail,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };
}
