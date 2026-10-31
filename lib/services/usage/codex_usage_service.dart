import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../models/provider_stats.dart';
import '../../models/usage_window.dart';
import '../platform/platform_bridge.dart';

class CodexActivitySnapshot {
  final bool isRecentlyWorking;
  final String? latestDetail;
  final bool hasRateLimitError;

  const CodexActivitySnapshot({
    this.isRecentlyWorking = false,
    this.latestDetail,
    this.hasRateLimitError = false,
  });
}

class CodexUsageService {
  final String? binaryPath;
  final Duration timeout;
  final Future<CodexRpcResult> Function({String? binaryPath, Duration timeout})?
      customRpcRunner;

  CodexUsageService({
    this.binaryPath,
    this.timeout = const Duration(seconds: 25),
    this.customRpcRunner,
  });

  static const Set<String> _validPlans = {
    'free',
    'go',
    'plus',
    'pro',
    'team',
    'business',
    'enterprise',
    'edu',
  };

  /// Ported 1:1 from `codex_usage.py::CodexUsageClient.check()`.
  Future<ProviderStats> check() async {
    final runner = customRpcRunner ?? PlatformBridge.runCodexAppServerRpc;
    final rpc = await runner(binaryPath: binaryPath, timeout: timeout);

    if (rpc.errorMessage != null && rpc.errorMessage!.isNotEmpty) {
      // Attempt local session fallback if app-server is not installed or unavailable
      final fallback = await _tryLocalSessionFallback();
      if (fallback != null) {
        return fallback;
      }
      return emptyQuota(
        'Codex · ChatGPT-Abo',
        detail: rpc.errorMessage!,
        status: 'error',
      );
    }

    final account = rpc.account;
    final identity = account != null ? account['account'] : null;
    if (identity is! Map ||
        !(identity['type'] == 'chatgpt' ||
            identity['type'] == 'chatgptAuthTokens')) {
      return emptyQuota(
        'Codex · ChatGPT-Abo',
        detail:
            'Bitte zuerst in der offiziellen Codex-App oder CLI mit deinem ChatGPT-Abo anmelden. Ein API-Schlüssel liefert keine Abo-Limits.',
        status: 'unauthorized',
      );
    }

    final stats = codexUsage(rpc.rateLimits);
    if (stats == null) {
      return emptyQuota(
        'Codex · ChatGPT-Abo',
        detail:
            'Codex ist angemeldet, meldet aber keine lesbaren 5-Stunden-/Wochenwerte für dieses Konto.',
        authenticated: true,
      );
    }

    final plan = identity['planType']?.toString().toLowerCase();
    if (plan != null && _validPlans.contains(plan)) {
      final cap = plan[0].toUpperCase() + plan.substring(1);
      stats.source += ' · $cap';
    }
    return stats;
  }

  /// Inspects `~/.codex/sessions` and `~/.codex/history.jsonl` for fallback usage metrics if `app-server` is offline.
  Future<ProviderStats?> _tryLocalSessionFallback() async {
    if (!PlatformBridge.isDesktop) return null;
    final home = PlatformBridge.homeDirectory;
    if (home.isEmpty) return null;
    final codexDir = p.join(home, '.codex');
    if (!await PlatformBridge.directoryExists(codexDir)) return null;

    final sessionsDir = p.join(codexDir, 'sessions');
    final files = await PlatformBridge.listFilesRecursive(
      sessionsDir,
      extensionFilter: '.jsonl',
      maxFiles: 60,
    );
    if (files.isEmpty) return null;

    final now = DateTime.now().toUtc();
    final fiveHoursAgo = now.subtract(const Duration(hours: 5));
    final sevenDaysAgo = now.subtract(const Duration(days: 7));

    var tokens5h = 0;
    var tokens7d = 0;
    DateTime? earliest5h;

    for (final file in files.take(25)) {
      if (file.modified.toUtc().isBefore(sevenDaysAgo)) continue;
      final content = await PlatformBridge.readFileString(file.path);
      if (content == null || content.isEmpty) continue;
      for (final line in const LineSplitter().convert(content)) {
        if (line.trim().isEmpty) continue;
        try {
          final row = jsonDecode(line);
          if (row is! Map) continue;
          final tsStr = row['timestamp']?.toString() ?? row['ts']?.toString();
          final ts = tsStr != null ? DateTime.tryParse(tsStr)?.toUtc() : file.modified.toUtc();
          if (ts == null || ts.isBefore(sevenDaysAgo)) continue;
          final usage = row['usage'] ?? row['token_usage'];
          var total = 0;
          if (usage is Map) {
            total = (int.tryParse(usage['total_tokens']?.toString() ?? '0') ?? 0) +
                (int.tryParse(usage['input_tokens']?.toString() ?? '0') ?? 0) +
                (int.tryParse(usage['output_tokens']?.toString() ?? '0') ?? 0);
          } else {
            total = 1200; // Estimated per turn when token counts are omitted
          }
          tokens7d += total;
          if (ts.isAfter(fiveHoursAgo)) {
            tokens5h += total;
            if (earliest5h == null || ts.isBefore(earliest5h)) {
              earliest5h = ts;
            }
          }
        } catch (_) {}
      }
    }

    if (tokens7d == 0 && tokens5h == 0) return null;
    final pct5h = ((tokens5h / 450000.0) * 100.0).clamp(0.0, 100.0);
    final pct7d = ((tokens7d / 3500000.0) * 100.0).clamp(0.0, 100.0);
    final reset5h = (earliest5h ?? now)
        .add(const Duration(hours: 5))
        .toUtc()
        .toIso8601String();
    final reset7d = now.add(const Duration(days: 3)).toUtc().toIso8601String();

    return quotaStats(
      [
        UsageWindow(
          key: 'five_hour',
          title: '5 Stunden',
          usedPercent: (pct5h * 10.0).round() / 10.0,
          resetsAt: reset5h,
        ),
        UsageWindow(
          key: 'seven_day',
          title: 'Woche',
          usedPercent: (pct7d * 10.0).round() / 10.0,
          resetsAt: reset7d,
        ),
      ],
      'Codex · Lokale Sessions',
      authenticated: true,
    );
  }

  /// Checks `~/.codex/sessions` and `~/.codex/history.jsonl` for live agent activity in the last few seconds.
  Future<CodexActivitySnapshot> checkLiveActivity({
    Duration activeThreshold = const Duration(seconds: 10),
  }) async {
    if (!PlatformBridge.isDesktop) return const CodexActivitySnapshot();
    final home = PlatformBridge.homeDirectory;
    if (home.isEmpty) return const CodexActivitySnapshot();
    final sessionsDir = p.join(home, '.codex', 'sessions');
    final files = await PlatformBridge.listFilesRecursive(
      sessionsDir,
      extensionFilter: '.jsonl',
      maxFiles: 20,
    );
    if (files.isEmpty) return const CodexActivitySnapshot();
    final newest = files.first;
    final diff = DateTime.now().difference(newest.modified);
    final isRecent = !diff.isNegative && diff <= activeThreshold;
    if (!isRecent) return const CodexActivitySnapshot();

    final content = await PlatformBridge.readFileString(newest.path);
    if (content != null && content.isNotEmpty) {
      final lines = const LineSplitter()
          .convert(content)
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.isNotEmpty) {
        final lastLine = lines.last.toLowerCase();
        if (lastLine.contains('429') ||
            lastLine.contains('rate_limit') ||
            lastLine.contains('quota_exceeded') ||
            lastLine.contains('usage limit')) {
          return const CodexActivitySnapshot(
            isRecentlyWorking: false,
            latestDetail: 'Rate-Limit erreicht (429)',
            hasRateLimitError: true,
          );
        }
      }
    }
    return const CodexActivitySnapshot(
      isRecentlyWorking: true,
      latestDetail: 'Codex Session aktiv...',
    );
  }
}
