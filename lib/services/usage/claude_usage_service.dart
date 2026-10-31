import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../../models/agent_status.dart';
import '../../models/provider_stats.dart';
import '../../models/usage_window.dart';
import '../platform/platform_bridge.dart';

class ClaudeLiveSignal {
  final TrafficLightState state;
  final String detail;
  final bool hasError;

  const ClaudeLiveSignal({
    required this.state,
    required this.detail,
    this.hasError = false,
  });
}

class ClaudeUsageService {
  final http.Client? httpClient;

  const ClaudeUsageService({this.httpClient});

  /// Checks Claude Code usage by combining:
  /// 1. Structured usage payload if present in `~/.claude/usage_state.json`
  /// 2. Real token consumption scanned from `~/.claude/projects/**/*.jsonl` (5h and Week windows)
  /// 3. Cached `.tracker/usage.json` when available
  Future<ProviderStats> check({ProviderStats? cachedStats}) async {
    if (!PlatformBridge.isDesktop) {
      return cachedStats ??
          emptyQuota(
            'Claude Code',
            detail: 'Bereit für Desktop-Sync oder Demo-Modus.',
          );
    }

    final home = PlatformBridge.homeDirectory;
    if (home.isEmpty) {
      return cachedStats ??
          emptyQuota('Claude Code', detail: 'Kein Benutzerverzeichnis gefunden.');
    }

    final claudeDir = p.join(home, '.claude');
    final hasClaudeDir = await PlatformBridge.directoryExists(claudeDir);
    if (!hasClaudeDir && cachedStats != null) {
      return cachedStats;
    }

    // 0. Real plan usage (same numbers as Claude's "Plan usage limits") via the signed-in Claude Code account.
    final live = await _fetchPlanUsage(claudeDir);
    if (live != null) return live;

    // 1. Check if `~/.claude/usage_state.json` has an observed claude.ai usage snapshot
    final usageStateFile = p.join(claudeDir, 'usage_state.json');
    final usageStateContent = await PlatformBridge.readFileString(usageStateFile);
    if (usageStateContent != null && usageStateContent.isNotEmpty) {
      try {
        final decoded = jsonDecode(usageStateContent);
        if (decoded is Map<String, dynamic>) {
          final parsed = claudeUsage(decoded);
          if (parsed != null) return parsed;
        }
      } catch (_) {}
    }

    // 2. Scan `~/.claude/projects/**/*.jsonl` for local Claude Code CLI usage
    final projectsDir = p.join(claudeDir, 'projects');
    final jsonlFiles = await PlatformBridge.listFilesRecursive(
      projectsDir,
      extensionFilter: '.jsonl',
      maxFiles: 120,
    );

    if (jsonlFiles.isNotEmpty) {
      final now = DateTime.now().toUtc();
      final fiveHoursAgo = now.subtract(const Duration(hours: 5));
      final sevenDaysAgo = now.subtract(const Duration(days: 7));

      var tokens5h = 0;
      var tokens7d = 0;
      DateTime? earliest5h;
      // Claude logs one assistant message as several JSONL lines with the same usage: count each id once.
      final seenMessageIds = <String>{};

      for (final file in jsonlFiles.take(40)) {
        if (file.modified.toUtc().isBefore(sevenDaysAgo)) continue;
        final content = await PlatformBridge.readFileString(file.path);
        if (content == null || content.isEmpty) continue;

        for (final line in const LineSplitter().convert(content)) {
          if (line.trim().isEmpty) continue;
          try {
            final row = jsonDecode(line);
            if (row is! Map) continue;
            final tsRaw = row['timestamp']?.toString();
            final ts = tsRaw != null
                ? DateTime.tryParse(tsRaw)?.toUtc()
                : file.modified.toUtc();
            if (ts == null || ts.isBefore(sevenDaysAgo)) continue;

            // Extract token count from `message.usage` or top-level `usage`
            Map? usage;
            if (row['message'] is Map) {
              usage = (row['message'] as Map)['usage'] as Map?;
            }
            usage ??= row['usage'] as Map?;

            final msgId = row['message'] is Map ? (row['message'] as Map)['id']?.toString() : null;
            if (msgId != null && !seenMessageIds.add(msgId)) continue;

            var turnTokens = 0;
            if (usage != null) {
              final input =
                  int.tryParse(usage['input_tokens']?.toString() ?? '0') ?? 0;
              final output =
                  int.tryParse(usage['output_tokens']?.toString() ?? '0') ?? 0;
              final cacheCreation = int.tryParse(
                    usage['cache_creation_input_tokens']?.toString() ?? '0',
                  ) ??
                  0;
              // Cached reads count at 10% weight towards rate limits
              final cacheRead = int.tryParse(
                    usage['cache_read_input_tokens']?.toString() ?? '0',
                  ) ??
                  0;
              turnTokens = input + output + cacheCreation + (cacheRead ~/ 10);
            }
            if (turnTokens <= 0) continue;

            tokens7d += turnTokens;
            if (ts.isAfter(fiveHoursAgo)) {
              tokens5h += turnTokens;
              if (earliest5h == null || ts.isBefore(earliest5h)) {
                earliest5h = ts;
              }
            }
          } catch (_) {
            continue;
          }
        }
      }

      if (tokens7d > 0 || tokens5h > 0) {
        final reset5h = (earliest5h ?? now)
            .add(const Duration(hours: 5))
            .toUtc()
            .toIso8601String();
        final nextMonday = now.add(Duration(days: (8 - now.weekday) % 7 + 1));
        final reset7d = DateTime.utc(
          nextMonday.year,
          nextMonday.month,
          nextMonday.day,
          7,
        ).toIso8601String();

        final windows = <UsageWindow>[
          UsageWindow(
            key: 'five_hour',
            title: '5 Stunden',
            resetsAt: reset5h,
            customQuotaLabel: '${_formatTokens(tokens5h)} Tokens',
          ),
          UsageWindow(
            key: 'seven_day',
            title: 'Woche',
            resetsAt: reset7d,
            customQuotaLabel: '${_formatTokens(tokens7d)} Tokens',
          ),
        ];
        return quotaStats(
          windows,
          'Claude Code · Lokale JSONL-Telemetrie (Verbrauch, kein Abo-Limit)',
          authenticated: true,
        );
      }
    }

    if (cachedStats != null) {
      return cachedStats;
    }

    return emptyQuota(
      'Claude-Abo',
      detail:
          'Keine aktiven Claude-Code-Sessions in ~/.claude/projects gefunden. Starte Claude Code oder verbinde dein Abo.',
    );
  }

  /// Asks Anthropic for the account's real 5h / weekly utilization using Claude Code's own login token.
  /// The token stays on this machine and is only sent to api.anthropic.com. Returns null on any problem
  /// (no login, expired token, offline, macOS keychain login), so callers fall back to the local estimate.
  Future<ProviderStats?> checkLive(String claudeDir) => _fetchPlanUsage(claudeDir);

  Future<ProviderStats?> _fetchPlanUsage(String claudeDir) async {
    final client = httpClient ?? http.Client();
    try {
      final raw = await PlatformBridge.readFileString(p.join(claudeDir, '.credentials.json'));
      if (raw == null || raw.isEmpty) return null;
      final oauth = (jsonDecode(raw) as Map)['claudeAiOauth'];
      if (oauth is! Map) return null;
      final token = oauth['accessToken']?.toString() ?? '';
      final expiresAt = (oauth['expiresAt'] as num?)?.toInt();
      if (token.isEmpty ||
          (expiresAt != null && expiresAt <= DateTime.now().millisecondsSinceEpoch)) {
        return null;
      }
      final res = await client.get(
        Uri.parse('https://api.anthropic.com/api/oauth/usage'),
        headers: {
          'Authorization': 'Bearer $token',
          'anthropic-beta': 'oauth-2025-04-20',
        },
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final parsed = claudeUsage(jsonDecode(res.body) as Map<String, dynamic>);
      if (parsed == null) return null;
      return quotaStats(parsed.windows, 'Claude Code · Abo (live)', authenticated: true);
    } catch (_) {
      return null;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Inspects the most recently modified `~/.claude/projects/**/*.jsonl` file to detect live tool execution,
  /// permission prompts, or 429 rate-limit errors even if a hook was missed.
  Future<ClaudeLiveSignal?> checkLiveJsonlSignal({
    Duration activeWindow = const Duration(seconds: 12),
  }) async {
    if (!PlatformBridge.isDesktop) return null;
    final home = PlatformBridge.homeDirectory;
    if (home.isEmpty) return null;
    final projectsDir = p.join(home, '.claude', 'projects');
    final files = await PlatformBridge.listFilesRecursive(
      projectsDir,
      extensionFilter: '.jsonl',
      maxFiles: 25,
    );
    if (files.isEmpty) return null;
    final newest = files.first;
    final age = DateTime.now().difference(newest.modified);
    if (age.isNegative || age > activeWindow) {
      return null;
    }
    final content = await PlatformBridge.readFileString(newest.path);
    if (content == null || content.isEmpty) return null;
    final lines = const LineSplitter()
        .convert(content)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final tail = lines.last;
    final lower = tail.toLowerCase();
    if (lower.contains('429') ||
        lower.contains('overloaded') ||
        lower.contains('usage limit reached') ||
        lower.contains('quota_exceeded')) {
      return const ClaudeLiveSignal(
        state: TrafficLightState.outOfUsage,
        detail: 'Rate-Limit / Quota erschöpft',
        hasError: true,
      );
    }
    if (lower.contains('permission_prompt') ||
        lower.contains('ask_user') ||
        lower.contains('waiting for permission')) {
      return const ClaudeLiveSignal(
        state: TrafficLightState.needsInput,
        detail: 'Wartet auf Tool-Freigabe',
      );
    }
    if (lower.contains('"tool_use"') || lower.contains('"pretooluse"')) {
      return const ClaudeLiveSignal(
        state: TrafficLightState.working,
        detail: 'Führt Tool aus...',
      );
    }
    return const ClaudeLiveSignal(
      state: TrafficLightState.working,
      detail: 'Generiert Antwort...',
    );
  }

  static String _formatTokens(int tokens) {
    if (tokens >= 1000000) {
      return '${(tokens / 1000000.0).toStringAsFixed(1)}M';
    }
    if (tokens >= 1000) {
      return '${(tokens / 1000.0).round()}k';
    }
    return tokens.toString();
  }
}
