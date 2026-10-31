import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../models/provider_stats.dart';
import '../../models/usage_window.dart';
import '../platform/platform_bridge.dart';

/// Ported 1:1 from `usage_cache.py::UsageCache`.
class UsageCacheService {
  final String? customPath;

  UsageCacheService({this.customPath});

  static const Set<String> _validProviders = {
    'claude',
    'chatgpt',
    'gemini_chat',
    'antigravity',
  };

  Future<String> _resolveCachePath() async {
    if (customPath != null && customPath!.isNotEmpty) {
      return customPath!;
    }
    const localTracker = '.tracker/usage.json';
    if (await PlatformBridge.fileExists(localTracker)) {
      return localTracker;
    }
    final home = PlatformBridge.homeDirectory;
    if (home.isNotEmpty) {
      final homeTracker = p.join(home, '.tracker', 'usage.json');
      if (await PlatformBridge.fileExists(homeTracker)) {
        return homeTracker;
      }
      return localTracker;
    }
    return localTracker;
  }

  /// Parses raw JSON map into cached `ProviderStats` map, matching `UsageCache.load()`.
  static Map<String, ProviderStats> parseCachePayload(
    Map<String, dynamic>? payload,
  ) {
    final stats = <String, ProviderStats>{};
    if (payload == null || payload['version'] != 1) return stats;
    final providers = payload['providers'];
    if (providers is! Map) return stats;

    for (final entry in providers.entries) {
      final pid = entry.key.toString();
      final row = entry.value;
      if (!_validProviders.contains(pid) || row is! Map) {
        continue;
      }
      try {
        final checkedRaw = row['checked_at']?.toString() ?? '';
        final hasTz = checkedRaw.endsWith('Z') ||
            checkedRaw.endsWith('z') ||
            RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(checkedRaw);
        if (!hasTz) continue;
        final checked = DateTime.parse(checkedRaw);

        final windowsMap = row['windows'];
        if (windowsMap is! Map) continue;

        final parsed = <UsageWindow>[];
        for (final spec in windowSpecs(pid)) {
          final wRaw = windowsMap[spec.key];
          final wMap =
              wRaw is Map ? Map<String, dynamic>.from(wRaw) : <String, dynamic>{};
          final disabled = wMap['disabled'] == true;
          parsed.add(
            UsageWindow(
              key: spec.key,
              title: spec.title,
              usedPercent: disabled ? null : parsePercent(wMap['used_percent']),
              resetsAt: resetIso(wMap['resets_at']),
              group: spec.group,
              disabled: disabled,
            ),
          );
        }
        if (!parsed.any((w) => w.usedPercent != null)) {
          continue;
        }
        var source = row['source']?.toString() ?? '';
        if (source.length > 80) {
          source = source.substring(0, 80);
        }
        final result = quotaStats(parsed, source, authenticated: false);
        result.checkedAt = checked.toUtc().toIso8601String();
        result.stale = true;
        result.status = 'paused';
        result.detail =
            'Gespeicherter Messstand. Wird beim nächsten erfolgreichen Abruf aktualisiert.';
        stats[pid] = result;
      } catch (_) {
        continue;
      }
    }
    return stats;
  }

  Future<Map<String, ProviderStats>> load() async {
    if (PlatformBridge.isWeb) return {};
    try {
      final path = await _resolveCachePath();
      final content = await PlatformBridge.readFileString(path);
      if (content == null || content.isEmpty) return {};
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return parseCachePayload(decoded);
      }
    } catch (_) {}
    return {};
  }

  Future<void> put(String pid, ProviderStats stats) async {
    if (PlatformBridge.isWeb) return;
    if (!_validProviders.contains(pid) ||
        !stats.authenticated ||
        stats.stale ||
        !stats.windows.any((w) => w.usedPercent != null)) {
      return;
    }
    try {
      final path = await _resolveCachePath();
      Map<String, dynamic> existingProviders = {};
      final content = await PlatformBridge.readFileString(path);
      if (content != null && content.isNotEmpty) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is Map &&
              decoded['version'] == 1 &&
              decoded['providers'] is Map) {
            existingProviders =
                Map<String, dynamic>.from(decoded['providers'] as Map);
          }
        } catch (_) {}
      }
      final validKeys = {for (final s in windowSpecs(pid)) s.key};
      final windowsJson = <String, dynamic>{};
      for (final w in stats.windows) {
        if (validKeys.contains(w.key)) {
          windowsJson[w.key] = {
            'used_percent': w.usedPercent,
            'resets_at': w.resetsAt,
            'disabled': w.disabled,
          };
        }
      }
      existingProviders[pid] = {
        'checked_at': stats.checkedAt,
        'source': stats.source,
        'windows': windowsJson,
      };
      final outJson = const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'providers': existingProviders,
      });
      await PlatformBridge.writeFileString(path, outJson);
    } catch (_) {}
  }
}
