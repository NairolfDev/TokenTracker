import 'dart:convert';
import 'package:path/path.dart' as p;
import '../models/agent_status.dart';
import '../models/app_constants.dart';
import 'platform/platform_bridge.dart';

class HookInstallResult {
  final bool claudeInstalled;
  final bool antigravityInstalled;
  final bool codexInstalled;
  final List<String> updatedFiles;

  const HookInstallResult({
    this.claudeInstalled = false,
    this.antigravityInstalled = false,
    this.codexInstalled = false,
    this.updatedFiles = const [],
  });

  bool isInstalledFor(AgentType type) {
    switch (type) {
      case AgentType.claude:
        return claudeInstalled;
      case AgentType.antigravity:
        return antigravityInstalled;
      case AgentType.codex:
        return codexInstalled;
      case AgentType.custom:
        return false;
    }
  }
}

class HookInstallerService {
  final String? customHomeDir;

  HookInstallerService({this.customHomeDir});

  static const String _hookEndpoint =
      'http://127.0.0.1:${AppConstants.hookServerPort}/api/hook';

  /// Builds the silent, non-blocking shell command (1s timeout) that posts the hook event to `127.0.0.1:47832`.
  static String buildCurlCommand({
    required String agent,
    required String event,
    required String detail,
    required bool isWindows,
  }) {
    if (isWindows) {
      final escapedJson =
          '{\\"agent\\":\\"$agent\\",\\"event\\":\\"$event\\",\\"detail\\":\\"$detail\\"}';
      return 'curl.exe -s --connect-timeout 1 --max-time 2 -X POST $_hookEndpoint -H "Content-Type: application/json" -d "$escapedJson" -o nul || exit 0';
    } else {
      final rawJson = '{"agent":"$agent","event":"$event","detail":"$detail"}';
      return 'curl -s --connect-timeout 1 --max-time 2 -X POST $_hookEndpoint -H "Content-Type: application/json" -d \'$rawJson\' >/dev/null 2>&1 || true';
    }
  }

  /// Non-destructively merges `agentlights` hook definitions into an existing configuration map.
  /// Preserves all existing top-level keys, existing hook categories, and non-ampel hook commands.
  static Map<String, dynamic> mergeHooksIntoConfig(
    Map<String, dynamic> existing, {
    required String agentId,
    required bool isWindows,
  }) {
    final result = Map<String, dynamic>.from(existing);
    final rawHooks = result['hooks'];
    final hooksMap = rawHooks is Map
        ? Map<String, dynamic>.from(rawHooks)
        : <String, dynamic>{};

    void upsertHookRule({
      required String eventKey,
      String? matcher,
      required String hookEvent,
      required String detail,
    }) {
      final cmd = buildCurlCommand(
        agent: agentId,
        event: hookEvent,
        detail: detail,
        isWindows: isWindows,
      );

      final existingListRaw = hooksMap[eventKey];
      final existingList = existingListRaw is List
          ? existingListRaw
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList()
          : <Map<String, dynamic>>[];

      // Remove any previous `127.0.0.1:47832/api/hook` entry with the same matcher so we don't duplicate on re-run
      final cleanedList = <Map<String, dynamic>>[];
      for (final entry in existingList) {
        final entryMatcher = entry['matcher']?.toString();
        final innerHooks = entry['hooks'];
        if (innerHooks is List) {
          final filteredInner = innerHooks.where((h) {
            if (h is Map) {
              final c = h['command']?.toString() ?? '';
              if (c.contains('127.0.0.1:${AppConstants.hookServerPort}/api/hook') &&
                  entryMatcher == matcher) {
                return false;
              }
            }
            return true;
          }).toList();
          if (filteredInner.isNotEmpty) {
            final updatedEntry = Map<String, dynamic>.from(entry);
            updatedEntry['hooks'] = filteredInner;
            cleanedList.add(updatedEntry);
          }
        } else {
          final directCmd = entry['command']?.toString() ?? '';
          if (!directCmd.contains(
            '127.0.0.1:${AppConstants.hookServerPort}/api/hook',
          )) {
            cleanedList.add(entry);
          }
        }
      }

      final newRule = <String, dynamic>{
        'matcher': ?matcher,
        'hooks': [
          {
            'type': 'command',
            'command': cmd,
            // async + timeout: a status ping must never block or loop the agent
            'timeout': 3,
            'async': true,
          },
        ],
      };

      cleanedList.add(newRule);
      hooksMap[eventKey] = cleanedList;
    }

    if (agentId == 'claude') {
      upsertHookRule(
        eventKey: 'PreToolUse',
        matcher: '*',
        hookEvent: 'working',
        detail: 'Führt Tool aus...',
      );
      upsertHookRule(
        eventKey: 'Notification',
        matcher: 'permission_prompt',
        hookEvent: 'permission',
        detail: 'Wartet auf Freigabe',
      );
      upsertHookRule(
        eventKey: 'Stop',
        matcher: null,
        hookEvent: 'stop',
        detail: 'Idle',
      );
    } else if (agentId == 'antigravity') {
      upsertHookRule(
        eventKey: 'PreToolUse',
        matcher: '*',
        hookEvent: 'working',
        detail: 'Antigravity führt Tool aus...',
      );
      upsertHookRule(
        eventKey: 'BeforeTool',
        matcher: '*',
        hookEvent: 'working',
        detail: 'Antigravity führt Tool aus...',
      );
      upsertHookRule(
        eventKey: 'Notification',
        matcher: 'permission_prompt',
        hookEvent: 'permission',
        detail: 'Wartet auf Bestätigung',
      );
      upsertHookRule(
        eventKey: 'PermissionRequest',
        matcher: '*',
        hookEvent: 'permission',
        detail: 'Wartet auf Bestätigung',
      );
      upsertHookRule(
        eventKey: 'Stop',
        matcher: null,
        hookEvent: 'stop',
        detail: 'Idle',
      );
      upsertHookRule(
        eventKey: 'AfterAgent',
        matcher: null,
        hookEvent: 'stop',
        detail: 'Idle',
      );
    } else if (agentId == 'codex') {
      upsertHookRule(
        eventKey: 'SessionStart',
        matcher: null,
        hookEvent: 'working',
        detail: 'Codex Session gestartet',
      );
      upsertHookRule(
        eventKey: 'PreToolUse',
        matcher: '*',
        hookEvent: 'working',
        detail: 'Codex führt Tool aus...',
      );
      upsertHookRule(
        eventKey: 'PermissionRequest',
        matcher: '*',
        hookEvent: 'permission',
        detail: 'Wartet auf Freigabe',
      );
      upsertHookRule(
        eventKey: 'Stop',
        matcher: null,
        hookEvent: 'stop',
        detail: 'Idle',
      );
    }

    result['hooks'] = hooksMap;
    return result;
  }

  /// Safely backs up `filePath` to `filePath.bak`, parses existing JSON, merges hooks, and writes atomically.
  Future<bool> _patchJsonConfigFile(
    String filePath, {
    required String agentId,
    required bool isWindows,
  }) async {
    try {
      Map<String, dynamic> existing = {};
      if (await PlatformBridge.fileExists(filePath)) {
        // Create non-destructive backup `<filename>.bak` before modifying
        await PlatformBridge.copyFile(filePath, '$filePath.bak');
        final raw = await PlatformBridge.readFileString(filePath);
        if (raw != null && raw.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              existing = Map<String, dynamic>.from(decoded);
            }
          } catch (_) {
            // If existing file has malformed JSON, do not overwrite it destructively
            return false;
          }
        }
      }

      final merged = mergeHooksIntoConfig(
        existing,
        agentId: agentId,
        isWindows: isWindows,
      );
      final formatted = const JsonEncoder.withIndent('  ').convert(merged);
      return await PlatformBridge.writeFileString(filePath, '$formatted\n');
    } catch (_) {
      return false;
    }
  }

  static const String _statuslineMarker = 'agent-lights-statusline';

  // Claude Code feeds its status-line command a JSON payload with the account's real `rate_limits`.
  // The wrapper saves that payload for the app and then runs the user's previous status line unchanged.
  static const String _statuslineScriptWindows = r'''
$in = [Console]::In.ReadToEnd()
$dir = Join-Path $env:USERPROFILE '.claude'
try { [IO.File]::WriteAllText((Join-Path $dir 'agent-lights-statusline.json'), $in) } catch {}
$prevFile = Join-Path $dir 'agent-lights-statusline.prev'
if (Test-Path $prevFile) {
  $prev = (Get-Content $prevFile -Raw).Trim()
  if ($prev) {
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe'
    $psi.Arguments = '/d /s /c "' + $prev + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($in)
    $proc.StandardInput.Close()
    [Console]::Out.Write($proc.StandardOutput.ReadToEnd())
    $proc.WaitForExit()
  }
}
''';

  static const String _statuslineScriptUnix = r'''
d="$HOME/.claude"
input=$(cat)
printf '%s' "$input" > "$d/agent-lights-statusline.json" 2>/dev/null
[ -s "$d/agent-lights-statusline.prev" ] && printf '%s' "$input" | sh -c "$(cat "$d/agent-lights-statusline.prev")"
exit 0
''';

  /// Points `statusLine` at our wrapper and returns the command it replaced (null if there was none or it is ours).
  static ({Map<String, dynamic> settings, String? previous}) wrapStatusLine(
    Map<String, dynamic> existing,
    String wrapperCommand,
  ) {
    final result = Map<String, dynamic>.from(existing);
    final current = result['statusLine'];
    final currentMap = current is Map ? Map<String, dynamic>.from(current) : <String, dynamic>{};
    final command = currentMap['command']?.toString() ?? '';
    if (command.contains(_statuslineMarker)) return (settings: result, previous: null);
    result['statusLine'] = {...currentMap, 'type': 'command', 'command': wrapperCommand};
    return (settings: result, previous: command.isEmpty ? null : command);
  }

  Future<bool> _installClaudeStatusline(String home, bool isWindows) async {
    try {
      final dir = p.join(home, '.claude');
      final settingsPath = p.join(dir, 'settings.json');
      final raw = await PlatformBridge.readFileString(settingsPath);
      final decoded = raw == null || raw.trim().isEmpty ? <String, dynamic>{} : jsonDecode(raw);
      if (decoded is! Map) return false;
      final script = p.join(dir, '$_statuslineMarker.${isWindows ? 'ps1' : 'sh'}');
      final wrapperCommand = isWindows
          ? 'powershell -NoProfile -ExecutionPolicy Bypass -File "$script"'
          : 'sh "$script"';
      final wrapped = wrapStatusLine(Map<String, dynamic>.from(decoded), wrapperCommand);
      if (!await PlatformBridge.writeFileString(
        script,
        isWindows ? _statuslineScriptWindows : _statuslineScriptUnix,
      )) {
        return false;
      }
      if (wrapped.previous != null) {
        await PlatformBridge.writeFileString(p.join(dir, '$_statuslineMarker.prev'), wrapped.previous!);
        final formatted = const JsonEncoder.withIndent('  ').convert(wrapped.settings);
        return await PlatformBridge.writeFileString(settingsPath, '$formatted\n');
      }
      if (jsonEncode(wrapped.settings) == jsonEncode(decoded)) return true;
      final formatted = const JsonEncoder.withIndent('  ').convert(wrapped.settings);
      return await PlatformBridge.writeFileString(settingsPath, '$formatted\n');
    } catch (_) {
      return false;
    }
  }

  /// Automatically installs/updates non-destructive hooks for Claude Code, Google Antigravity, and OpenAI Codex.
  Future<HookInstallResult> ensureHooksInstalled() async {
    if (!PlatformBridge.isDesktop) {
      return const HookInstallResult(
        claudeInstalled: true,
        antigravityInstalled: true,
        codexInstalled: true,
      );
    }

    final home = customHomeDir ?? PlatformBridge.homeDirectory;
    if (home.isEmpty) return const HookInstallResult();

    final isWin = PlatformBridge.isWindows;
    final updated = <String>[];

    // 1. Claude Code (`~/.claude/settings.json`)
    final claudeSettingsPath = p.join(home, '.claude', 'settings.json');
    final claudeOk = await _patchJsonConfigFile(
      claudeSettingsPath,
      agentId: 'claude',
      isWindows: isWin,
    );
    if (claudeOk) {
      updated.add(claudeSettingsPath);
      await _installClaudeStatusline(home, isWin);
    }

    // 2. Google Antigravity (`~/.gemini/config/hooks.json`)
    final antigravityHooksPath =
        p.join(home, '.gemini', 'config', 'hooks.json');
    final agOk = await _patchJsonConfigFile(
      antigravityHooksPath,
      agentId: 'antigravity',
      isWindows: isWin,
    );
    if (agOk) updated.add(antigravityHooksPath);

    // 3. OpenAI Codex (`~/.codex/hooks.json`)
    final codexHooksPath = p.join(home, '.codex', 'hooks.json');
    final codexOk = await _patchJsonConfigFile(
      codexHooksPath,
      agentId: 'codex',
      isWindows: isWin,
    );
    if (codexOk) updated.add(codexHooksPath);

    return HookInstallResult(
      claudeInstalled: claudeOk,
      antigravityInstalled: agOk,
      codexInstalled: codexOk,
      updatedFiles: updated,
    );
  }
}
