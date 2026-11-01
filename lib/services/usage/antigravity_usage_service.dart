import 'dart:convert';
import 'package:path/path.dart' as p;
import '../../models/provider_stats.dart';
import '../../models/usage_window.dart';
import '../platform/platform_bridge.dart';

class LocalServer {
  final int pid;
  final int port;
  final String csrf;

  const LocalServer({
    required this.pid,
    required this.port,
    required this.csrf,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalServer &&
          other.pid == pid &&
          other.port == port &&
          other.csrf == csrf;

  @override
  int get hashCode => Object.hash(pid, port, csrf);

  @override
  String toString() => 'LocalServer(pid: $pid, port: $port, csrf: ***)';
}

const String kAntigravityQuotaMethod =
    '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary';
const String kAntigravityUserStatusMethod =
    '/exa.language_server_pb.LanguageServerService/GetUserStatus';
const String kAntigravitySource = 'Antigravity · lokaler Quota-Dienst';

const Map<String, (String, String)> kAntigravityBuckets = {
  'gemini-5h': ('gemini_five_hour', '5h'),
  'gemini-weekly': ('gemini_seven_day', 'weekly'),
  '3p-5h': ('claude_gpt_five_hour', '5h'),
  '3p-weekly': ('claude_gpt_seven_day', 'weekly'),
};

double _round2(double value) => (value * 100.0).round() / 100.0;

/// Ported 1:1 from `antigravity_usage.py::_flag(command, name)`.
String? extractFlag(String command, String name) {
  final escaped = RegExp.escape(name);
  final regex = RegExp(
    '(?:^|\\s)--$escaped(?:=|\\s+)(?:"([^"\\r\\n]*)"|([^\\s"]+))',
  );
  final match = regex.firstMatch(command);
  if (match == null) return null;
  return match.group(1) ?? match.group(2);
}

/// Ported 1:1 from `antigravity_usage.py::antigravity_usage(payload)`
/// plus extraction of detailed sub-limits for the expandable Antigravity drawer.
ProviderStats? antigravityUsage(Map<String, dynamic>? payload) {
  if (payload == null) return null;
  final response = payload['response'];
  if (response is! Map) return null;

  final buckets = <Map<String, dynamic>>[];
  final rawBuckets = response['buckets'];
  if (rawBuckets is List) {
    for (final b in rawBuckets) {
      if (b is Map) {
        buckets.add(Map<String, dynamic>.from(b));
      }
    }
  }
  final groups = response['groups'];
  if (groups is List) {
    for (final group in groups.take(16)) {
      if (group is Map && group['buckets'] is List) {
        for (final b in (group['buckets'] as List).take(32)) {
          if (b is Map) {
            buckets.add({
              ...Map<String, dynamic>.from(b),
              // A group holding only this one bucket (e.g. "Gemini 4 Argon") names it better than its id does.
              if ((group['buckets'] as List).length == 1) 'groupName': group['displayName']?.toString(),
            });
          }
        }
      }
    }
  }

  final found = <String, UsageWindow>{};
  final duplicates = <String>{};
  final extraSubLimits = <UsageWindow>[];
  final specs = {
    for (final s in windowSpecs('antigravity')) s.key: (s.title, s.group),
  };

  for (final bucket in buckets.take(128)) {
    final bucketId = bucket['bucketId'];
    if (bucketId is! String || bucketId.isEmpty) continue;

    final mapping = kAntigravityBuckets[bucketId];
    if (mapping == null) {
      // Extra model buckets (e.g. "Gemini 4 Argon", weekly only) may carry no label:
      // fall back to the bucket id minus its window suffix, e.g. "argon-weekly" -> "argon".
      final idSuffix = RegExp(r'[-_](5h|weekly)$').firstMatch(bucketId)?.group(1);
      final explicitModel = bucket['label'] ??
          bucket['modelName'] ??
          bucket['groupName'] ??
          (idSuffix == null
              ? null
              : bucketId.replaceFirst(RegExp(r'[-_](5h|weekly)$'), '').replaceAll(RegExp(r'[-_]+'), ' '));
      if (explicitModel == null || explicitModel.toString().trim().isEmpty) {
        continue;
      }
      final disabled = bucket['disabled'] == true;
      final fraction = parsePercent(bucket['remainingFraction']);
      if (!disabled && (fraction == null || fraction > 1.0)) {
        continue;
      }
      final label = explicitModel.toString().trim();
      final winDuration = bucket['window']?.toString() ??
          RegExp(r'[-_](5h|weekly)$').firstMatch(bucketId)?.group(1) ??
          'Quota';
      extraSubLimits.add(
        UsageWindow(
          key: 'sub_$bucketId',
          title: winDuration == '5h'
              ? '5 Stunden'
              : winDuration == 'weekly'
                  ? 'Woche'
                  : winDuration,
          usedPercent: disabled ? null : _round2(100.0 - fraction! * 100.0),
          resetsAt: resetIso(bucket['resetTime']),
          group: label,
          disabled: disabled,
        ),
      );
      continue;
    }

    final (key, duration) = mapping;
    final winField = bucket['window'];
    if (winField != null && winField != duration) {
      continue;
    }
    final disabled = bucket['disabled'] == true;
    final fraction = parsePercent(bucket['remainingFraction']);
    // remainingAmount is a separate oneof field, never a fraction or token balance.
    if (!disabled && (fraction == null || fraction > 1.0)) {
      continue;
    }
    final (title, group) = specs[key]!;
    final window = UsageWindow(
      key: key,
      title: title,
      usedPercent: disabled ? null : _round2(100.0 - fraction! * 100.0),
      resetsAt: resetIso(bucket['resetTime']),
      group: group,
      disabled: disabled,
    );
    if (found.containsKey(key) && found[key] != window) {
      duplicates.add(key);
    } else {
      found[key] = window;
    }
  }

  for (final key in duplicates) {
    found.remove(key);
  }
  if (found.isEmpty) return null;

  final windows = windowSpecs('antigravity')
      .map(
        (s) =>
            found[s.key] ??
            UsageWindow(key: s.key, title: s.title, group: s.group),
      )
      .toList();

  final allSubLimits = <UsageWindow>[
    ...windows,
    ...extraSubLimits,
  ];

  final stats = quotaStats(
    windows,
    kAntigravitySource,
    subLimits: allSubLimits,
  );
  stats.detail =
      'Verbleibende Antigravity-Kapazität je Modellgruppe. Limits und Reset-Zeiten stammen aus deiner laufenden Antigravity-Anmeldung.';
  if (windows.any((w) => w.disabled)) {
    stats.detail +=
        ' Nicht verfügbare Fenster sind im aktuellen Tarif deaktiviert.';
  }
  if (found.length < windows.length) {
    stats.detail += ' Nicht gemeldete Fenster bleiben unbekannt.';
  }
  return stats;
}

/// Ported 1:1 from `antigravity_usage.py::servers_from_processes(rows, netstat)`.
List<LocalServer> serversFromProcesses(Object? rows, String netstat) {
  final rowList = rows is List ? rows : [rows];
  final listeners = <int, Set<int>>{};

  for (final line in const LineSplitter().convert(netstat)) {
    final parts =
        line.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.length != 5 || parts[0] != 'TCP') continue;
    final loopbackLive = parts[3] == 'ESTABLISHED' && parts[1].startsWith('127.0.0.1:');
    if (parts[3] != 'LISTENING' && !loopbackLive) continue;
    final pid = int.tryParse(parts[4]);
    final addr = parts[1];
    final colonIdx = addr.lastIndexOf(':');
    if (pid == null || colonIdx < 0) continue;
    final port = int.tryParse(addr.substring(colonIdx + 1));
    if (port != null && port >= 1 && port <= 65535) {
      listeners.putIfAbsent(pid, () => <int>{}).add(port);
    }
  }

  final servers = <LocalServer>[];
  final csrfRegex = RegExp(r'^[A-Za-z0-9_.-]{8,512}$');

  for (final row in rowList.take(16)) {
    if (row is! Map) continue;
    final path = row['ExecutablePath'];
    final command = row['CommandLine'];
    final pid = row['ProcessId'];
    if (path is! String || command is! String || pid is! int) {
      continue;
    }
    final parts = path.replaceAll('\\', '/').toLowerCase().split('/');
    if (parts.length < 5) continue;
    final tail = parts.sublist(parts.length - 4);
    final isAntigravityBin = tail[0] == 'antigravity' &&
        tail[1] == 'resources' &&
        tail[2] == 'bin' &&
        (tail[3] == 'language_server.exe' ||
            tail[3].startsWith('language_server'));
    if (!isAntigravityBin) continue;

    if (extractFlag(command, 'override_ide_name') != 'antigravity') {
      continue;
    }
    final csrf = extractFlag(command, 'csrf_token');
    if (csrf == null || !csrfRegex.hasMatch(csrf)) {
      continue;
    }
    final ownedPorts = (listeners[pid]?.toList() ?? <int>[])..sort();
    final configured = extractFlag(command, 'https_server_port');
    if (configured != null && RegExp(r'^\d+$').hasMatch(configured)) {
      final cfgPort = int.tryParse(configured);
      if (cfgPort != null && ownedPorts.contains(cfgPort)) {
        ownedPorts.remove(cfgPort);
        ownedPorts.insert(0, cfgPort);
      }
    }
    for (final port in ownedPorts.take(4)) {
      servers.add(LocalServer(pid: pid, port: port, csrf: csrf));
    }
  }
  return servers;
}

class AntigravityUsageService {
  final Future<List<LocalServer>> Function()? customFinder;

  AntigravityUsageService({this.customFinder});

  /// Discovers running local Antigravity LanguageServer instances across Windows, Linux, and macOS.
  Future<List<LocalServer>> discoverServers() async {
    if (customFinder != null) {
      return customFinder!();
    }
    if (!PlatformBridge.isDesktop) return const [];

    if (PlatformBridge.isWindows) {
      final systemRoot =
          PlatformBridge.environment['SystemRoot'] ?? r'C:\Windows';
      final psPath = p.join(
        systemRoot,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final netstatPath = p.join(systemRoot, 'System32', 'netstat.exe');
      const query =
          "Get-CimInstance Win32_Process -Filter \"Name='language_server.exe'\" | "
          'Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress';

      final psResult = await PlatformBridge.runProcess(
        psPath,
        ['-NoProfile', '-NonInteractive', '-Command', query],
      );
      if (psResult == null || psResult.stdout.trim().isEmpty) {
        return const [];
      }
      final dynamic rows = jsonDecode(psResult.stdout.trim());
      final netstatResult = await PlatformBridge.runProcess(
        netstatPath,
        ['-ano', '-p', 'tcp'],
      );
      if (netstatResult == null) return const [];
      return serversFromProcesses(rows, netstatResult.stdout);
    }

    // Linux & macOS process discovery for Antigravity language_server
    final psResult = await PlatformBridge.runProcess(
      'ps',
      ['-eo', 'pid,args'],
    );
    if (psResult == null || psResult.stdout.trim().isEmpty) {
      return const [];
    }
    final servers = <LocalServer>[];
    final csrfRegex = RegExp(r'^[A-Za-z0-9_.-]{8,512}$');
    for (final line in const LineSplitter().convert(psResult.stdout)) {
      if (!line.contains('language_server') || !line.contains('antigravity')) {
        continue;
      }
      final trimmed = line.trim();
      final spaceIdx = trimmed.indexOf(' ');
      if (spaceIdx <= 0) continue;
      final pid = int.tryParse(trimmed.substring(0, spaceIdx));
      final cmd = trimmed.substring(spaceIdx + 1).trim();
      if (pid == null) continue;
      if (extractFlag(cmd, 'override_ide_name') != 'antigravity') continue;
      final csrf = extractFlag(cmd, 'csrf_token');
      if (csrf == null || !csrfRegex.hasMatch(csrf)) continue;
      final configured = extractFlag(cmd, 'https_server_port');
      if (configured != null) {
        final port = int.tryParse(configured);
        if (port != null && port >= 1 && port <= 65535) {
          servers.add(LocalServer(pid: pid, port: port, csrf: csrf));
        }
      }
    }
    return servers;
  }

  /// Enriches the sub-limits list with model configs from `GetUserStatus` if reported by the server.
  Future<List<UsageWindow>> _fetchModelSubLimits(
    LocalServer server,
    List<UsageWindow> baseSubLimits,
  ) async {
    final enriched = List<UsageWindow>.from(baseSubLimits);
    try {
      final res = await PlatformBridge.postLoopbackHttpsJson(
        server.port,
        kAntigravityUserStatusMethod,
        const <String, dynamic>{},
        {
          'x-codeium-csrf-token': server.csrf,
          'Connect-Protocol-Version': '1',
        },
        timeout: const Duration(seconds: 4),
      );
      if (res != null && res.statusCode == 200 && res.body.isNotEmpty) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map) {
          final userStatus = decoded['userStatus'];
          if (userStatus is Map) {
            final cascadeData = userStatus['cascadeModelConfigData'];
            final configs = cascadeData is Map
                ? cascadeData['clientModelConfigs']
                : null;
            if (configs is List) {
              for (final cfg in configs.take(12)) {
                if (cfg is! Map) continue;
                final label = cfg['label']?.toString();
                final quotaInfo = cfg['quotaInfo'];
                if (label == null || quotaInfo is! Map) continue;
                final remFrac = parsePercent(quotaInfo['remainingFraction']);
                if (remFrac == null || remFrac > 1.0) continue;
                final resetTime = resetIso(quotaInfo['resetTime']);
                enriched.add(
                  UsageWindow(
                    key: 'model_${label.toLowerCase().replaceAll(' ', '_')}',
                    title: 'Modell-Quota',
                    usedPercent: _round2(100.0 - remFrac * 100.0),
                    resetsAt: resetTime,
                    group: label,
                  ),
                );
              }
            }
          }
        }
      }
    } catch (_) {}
    return enriched;
  }

  /// Ported 1:1 from `AntigravityUsageClient.check()`.
  Future<ProviderStats> check() async {
    ProviderStats unavailable(
      String value,
      String detail, [
      String status = 'paused',
    ]) {
      final stats = emptyQuota(
        kAntigravitySource,
        detail: detail,
        status: status,
        providerId: 'antigravity',
      );
      stats.value = value;
      return stats;
    }

    List<LocalServer> servers;
    try {
      servers = await discoverServers();
    } catch (_) {
      return unavailable(
        'Abruf pausiert',
        'Antigravity konnte nicht lokal erkannt werden. Antigravity öffnen und erneut prüfen.',
      );
    }

    if (servers.isEmpty) {
      return unavailable(
        'Antigravity öffnen',
        'Antigravity starten und dort anmelden. Anschließend hier »Prüfen« wählen.',
      );
    }

    var unauthorized = false;
    var unsupported = false;
    final csrfRegex = RegExp(r'^[A-Za-z0-9_.-]{8,512}$');

    for (final server in servers.take(8)) {
      if (server.port < 1 ||
          server.port > 65535 ||
          !csrfRegex.hasMatch(server.csrf)) {
        continue;
      }
      try {
        final response = await PlatformBridge.postLoopbackHttpsJson(
          server.port,
          kAntigravityQuotaMethod,
          const {'forceRefresh': true},
          {
            'x-codeium-csrf-token': server.csrf,
            'Connect-Protocol-Version': '1',
          },
        );
        if (response == null) continue;
        if (response.statusCode == 401 || response.statusCode == 403) {
          unauthorized = true;
          continue;
        }
        if (response.statusCode != 200 ||
            response.contentLength > 1024 * 1024) {
          continue;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final stats = antigravityUsage(decoded);
          if (stats != null) {
            stats.subLimits =
                await _fetchModelSubLimits(server, stats.subLimits);
            return stats;
          }
        }
        unsupported = true;
      } catch (_) {
        continue;
      }
    }

    if (unsupported) {
      return unavailable(
        'Limits nicht lesbar',
        'Antigravity meldet derzeit keine unterstützten Quota-Fenster. In Antigravity → Models → View Usage prüfen.',
        'error',
      );
    }
    if (unauthorized) {
      return unavailable(
        'Anmeldung prüfen',
        'Antigravity erneut öffnen und die Anmeldung dort prüfen. Danach hier aktualisieren.',
      );
    }
    return unavailable(
      'Abruf pausiert',
      'Der lokale Antigravity-Dienst antwortet nicht. Antigravity öffnen und erneut prüfen.',
    );
  }

  /// Checks whether `~/.gemini/antigravity` has active log/artifact modifications in the last few seconds.
  Future<bool> hasRecentFileActivity({
    Duration threshold = const Duration(seconds: 12),
  }) async {
    if (!PlatformBridge.isDesktop) return false;
    final home = PlatformBridge.homeDirectory;
    if (home.isEmpty) return false;
    final brainDir = p.join(home, '.gemini', 'antigravity', 'brain');
    final files = await PlatformBridge.listFilesRecursive(
      brainDir,
      maxFiles: 40,
    );
    if (files.isEmpty) return false;
    final diff = DateTime.now().difference(files.first.modified);
    return !diff.isNegative && diff <= threshold;
  }

  /// Ported 1:1 from `antigravity_usage.py::open_antigravity()`.
  static Future<bool> openAntigravity() async {
    if (!PlatformBridge.isWindows) return false;
    for (final envKey in const ['LOCALAPPDATA', 'ProgramFiles']) {
      final root = PlatformBridge.environment[envKey] ?? '';
      if (root.isEmpty) continue;
      final candidates = [
        p.join(root, 'Programs', 'Antigravity', 'Antigravity.exe'),
        p.join(root, 'Antigravity', 'Antigravity.exe'),
      ];
      for (final path in candidates) {
        if (await PlatformBridge.fileExists(path)) {
          return PlatformBridge.spawnDetached(path, const []);
        }
      }
    }
    return false;
  }
}
