import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:agent_ampel/controllers/ampel_controller.dart';
import 'package:agent_ampel/models/agent_status.dart';
import 'package:agent_ampel/models/app_constants.dart';
import 'package:agent_ampel/models/custom_agent.dart';
import 'package:agent_ampel/models/provider_stats.dart';
import 'package:agent_ampel/models/usage_window.dart';
import 'package:agent_ampel/services/auto_updater_service.dart';
import 'package:agent_ampel/services/hook_event.dart';
import 'package:agent_ampel/services/hook_installer_service.dart';
import 'package:agent_ampel/services/usage/antigravity_usage_service.dart';
import 'package:agent_ampel/services/usage/claude_usage_service.dart';
import 'package:agent_ampel/services/usage/usage_cache_service.dart';
import 'package:agent_ampel/ui/screens/ampel_hud_screen.dart';
import 'package:agent_ampel/ui/widgets/agent_logo_widget.dart';
import 'package:agent_ampel/ui/widgets/antigravity_limits_drawer.dart';
import 'package:agent_ampel/ui/widgets/depleting_usage_ring.dart';
import 'package:agent_ampel/ui/widgets/traffic_light_widget.dart';

Map<String, dynamic> _antigravityFixtureQuotas() {
  return {
    'response': {
      'groups': [
        {
          'displayName': 'Gemini Models',
          'buckets': [
            {
              'bucketId': 'gemini-weekly',
              'window': 'weekly',
              'remainingFraction': 0.33,
              'resetTime': '2030-10-09T07:55:59Z',
            },
            {
              'bucketId': 'gemini-5h',
              'window': '5h',
              'remainingFraction': 0.76,
              'resetTime': '2030-10-02T17:45:10Z',
            },
          ],
        },
        {
          'displayName': 'Claude and GPT models',
          'buckets': [
            {
              'bucketId': '3p-weekly',
              'window': 'weekly',
              'remainingFraction': 0.9,
              'resetTime': '2030-10-09T12:45:10Z',
            },
            {
              'bucketId': '3p-5h',
              'window': '5h',
              'remainingFraction': 0.12,
              'resetTime': '2030-10-02T17:45:10Z',
            },
          ],
        },
      ],
    },
  };
}

Map<String, dynamic> _codexFixture({Object? primary = 35, Object? secondary = 90}) {
  return {
    'rateLimits': {
      'limitId': 'codex',
      'primary': {
        'usedPercent': primary,
        'windowDurationMins': 300,
        'resetsAt': 1900000000,
      },
      'secondary': {
        'usedPercent': secondary,
        'windowDurationMins': 10080,
        'resetsAt': 1900500000,
      },
    },
  };
}
void main() {
  customAgentAndArgonTests();
  claudePlanUsageTest();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // =========================================================================
  // 1. ANTIGRAVITY USAGE & PROCESS DISCOVERY TESTS
  // =========================================================================
  group('1. Antigravity Usage & Process Discovery Tests', () {
    test('distinct model pools, durations, remaining_percent, and resetTime', () {
      final result = antigravityUsage(_antigravityFixtureQuotas());
      expect(result, isNotNull);
      expect(result!.authenticated, isTrue);
      expect(
        result.windows.map((w) => w.remainingPercent).toList(),
        equals([76.0, 33.0, 12.0, 90.0]),
      );
      expect(
        result.windows.map((w) => w.group).toList(),
        equals(['Gemini', 'Gemini', 'Claude / GPT', 'Claude / GPT']),
      );
      expect(result.label, equals('Claude / GPT · 5 Stunden übrig'));
      expect(result.value, equals('12%'));
      expect(
        DateTime.parse(result.windows[1].resetsAt!).toUtc(),
        equals(DateTime.parse('2030-10-09T07:55:59Z').toUtc()),
      );
    });

    test('zero is exhausted and one is full capacity', () {
      final payload = _antigravityFixtureQuotas();
      final groups = payload['response']['groups'] as List;
      (groups[0]['buckets'] as List)[0]['remainingFraction'] = 0;
      (groups[0]['buckets'] as List)[1]['remainingFraction'] = 1;

      final result = antigravityUsage(payload)!;
      expect(result.windows[0].remainingPercent, equals(100.0));
      expect(result.windows[1].remainingPercent, equals(0.0));
      expect(result.status, equals('warning'));
    });

    test('missing remainingFraction or credit remainingAmount is unknown', () {
      final payload = _antigravityFixtureQuotas();
      final groups = payload['response']['groups'] as List;
      final row = (groups[0]['buckets'] as List)[1] as Map<String, dynamic>;
      row.remove('remainingFraction');
      row['remainingAmount'] = '300';

      final result = antigravityUsage(payload)!;
      expect(result.windows[0].remainingPercent, isNull);
      expect(result.windows[1].remainingPercent, equals(33.0));
    });

    test('invalid fractions are never treated as capacity', () {
      for (final bad in [true, -1, 1.2, double.nan, null, <String, dynamic>{}]) {
        final payload = {
          'response': {
            'buckets': [
              {
                'bucketId': 'gemini-5h',
                'window': '5h',
                'remainingFraction': bad,
              },
            ],
          },
        };
        expect(antigravityUsage(payload), isNull);
      }
    });

    test('disabled bucket is not full capacity and marks disabled=true', () {
      final payload = _antigravityFixtureQuotas();
      final groups = payload['response']['groups'] as List;
      (groups[1]['buckets'] as List)[1]['disabled'] = true;

      final result = antigravityUsage(payload)!;
      expect(result.windows[2].remainingPercent, isNull);
      expect(result.windows[2].disabled, isTrue);
      expect(result.value, equals('33%'));
    });

    test('unknown or contradictory window is ignored, named sub-limits extracted for drawer', () {
      expect(
        antigravityUsage({
          'response': {
            'buckets': [
              {'bucketId': 'unknown-5h', 'window': '5h', 'remainingFraction': 1},
            ],
          },
        }),
        isNull,
      );
      expect(
        antigravityUsage({
          'response': {
            'buckets': [
              {'bucketId': 'gemini-5h', 'window': 'weekly', 'remainingFraction': 1},
            ],
          },
        }),
        isNull,
      );

      // Additional named model sub-limits are extracted into subLimits for the drawer
      final payload = _antigravityFixtureQuotas();
      final groups = payload['response']['groups'] as List;
      (groups[0]['buckets'] as List).add({
        'bucketId': 'gemini-2.5-pro-5h',
        'label': 'Gemini 2.5 Pro',
        'window': '5h',
        'remainingFraction': 0.65,
        'resetTime': '2030-10-02T17:45:10Z',
      });
      final result = antigravityUsage(payload)!;
      expect(result.windows.length, equals(4));
      expect(result.subLimits.length, equals(5));
      expect(result.subLimits.last.group, equals('Gemini 2.5 Pro'));
      expect(result.subLimits.last.remainingPercent, equals(65.0));
    });

    test('conflicting duplicate bucket becomes unknown', () {
      final payload = _antigravityFixtureQuotas();
      (payload['response'] as Map<String, dynamic>)['buckets'] = [
        {
          'bucketId': 'gemini-5h',
          'window': '5h',
          'remainingFraction': 1,
        },
      ];
      final result = antigravityUsage(payload)!;
      expect(result.windows[0].remainingPercent, isNull);
    });

    test('serversFromProcesses filters strictly for Antigravity, csrf_token, and prioritizes https_server_port', () {
      final rows = [
        {
          'ProcessId': 42,
          'ExecutablePath':
              r'C:\Users\test\Programs\Antigravity\resources\bin\language_server.exe',
          'CommandLine':
              'server --override_ide_name antigravity --csrf_token "local-test-token" --https_server_port 61455',
        },
        {
          'ProcessId': 99,
          'ExecutablePath':
              r'C:\Programs\Windsurf\resources\bin\language_server.exe',
          'CommandLine':
              'server --override_ide_name antigravity --csrf_token foreign-token',
        },
      ];
      const netstat = ' TCP 127.0.0.1:61454 0.0.0.0:0 LISTENING 42\n'
          ' TCP 127.0.0.1:61455 0.0.0.0:0 LISTENING 42\n'
          ' TCP 127.0.0.1:61454 127.0.0.1:99 ESTABLISHED 42\n'
          ' TCP 127.0.0.1:7777 0.0.0.0:0 LISTENING 99\n';

      final servers = serversFromProcesses(rows, netstat);
      expect(
        servers,
        equals([
          const LocalServer(pid: 42, port: 61455, csrf: 'local-test-token'),
          const LocalServer(pid: 42, port: 61454, csrf: 'local-test-token'),
        ]),
      );
      expect(servers.toString(), isNot(contains('local-test-token')));

      rows[0]['CommandLine'] =
          'server --override_ide_name windsurf --csrf_token local-test-token';
      expect(serversFromProcesses(rows, netstat), isEmpty);
    });

    test('Antigravity cache keeps groups and does not persist identity or secrets', () async {
      final tempDir = await Directory.systemTemp.createTemp('ampel_ag_cache_');
      try {
        final cacheFile = p.join(tempDir.path, 'usage.json');
        final cache = UsageCacheService(customPath: cacheFile);
        final measured = antigravityUsage(_antigravityFixtureQuotas())!;
        await cache.put('antigravity', measured);

        final rawText = await File(cacheFile).readAsString();
        expect(rawText, isNot(contains('csrf')));

        final restoredMap = await cache.load();
        final restored = restoredMap['antigravity']!;
        expect(restored.stale, isTrue);
        expect(restored.authenticated, isFalse);
        expect(
          restored.windows.map((w) => w.remainingPercent).toList(),
          equals([76.0, 33.0, 12.0, 90.0]),
        );
        expect(restored.windows[2].group, equals('Claude / GPT'));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  // =========================================================================
  // 2. CODEX, CLAUDE & SUBSCRIPTION USAGE TESTS
  // =========================================================================
  group('2. Codex, Claude & Subscription Usage Tests', () {
    test('codexUsage tracks independent capacity and resets for 5h (300m) and Week (10080m)', () {
      final result = codexUsage(_codexFixture(primary: 0, secondary: 100))!;
      expect(
        result.windows.map((w) => w.remainingPercent).toList(),
        equals([100.0, 0.0]),
      );
      expect(result.value, equals('0%'));
      expect(result.label, equals('Woche übrig'));
      expect(result.status, equals('warning'));
      expect(
        result.windows[0].resetsAt,
        isNot(equals(result.windows[1].resetsAt)),
      );
    });

    test('codexUsage windowDurationMins defines 5h and Week regardless of primary/secondary order', () {
      final payload = _codexFixture();
      final snapshot = payload['rateLimits'] as Map<String, dynamic>;
      final tmp = snapshot['primary'];
      snapshot['primary'] = snapshot['secondary'];
      snapshot['secondary'] = tmp;

      final result = codexUsage(payload)!;
      expect(
        result.windows.map((w) => w.remainingPercent).toList(),
        equals([65.0, 10.0]),
      );
    });

    test('codexUsage bucket wins over other model limits and missing 5h window sets detail', () {
      final payload = _codexFixture(primary: 99, secondary: 99);
      payload['rateLimitsByLimitId'] = {
        'codex': _codexFixture(primary: 25, secondary: 60)['rateLimits'],
        'other': _codexFixture(primary: 100, secondary: 100)['rateLimits'],
      };
      expect(
        codexUsage(payload)!.windows.map((w) => w.remainingPercent).toList(),
        equals([75.0, 40.0]),
      );

      // Missing 5h window reports explanatory detail
      final weekOnlyPayload = {
        'rateLimits': {
          'limitId': 'codex',
          'secondary': {
            'usedPercent': 40,
            'windowDurationMins': 10080,
            'resetsAt': 1900500000,
          },
        },
      };
      final weekOnly = codexUsage(weekOnlyPayload)!;
      expect(weekOnly.windows[0].remainingPercent, isNull);
      expect(weekOnly.windows[1].remainingPercent, equals(60.0));
      expect(
        weekOnly.detail,
        contains('Codex meldet für dieses Konto kein 5-Stunden-Fenster'),
      );
    });

    test('claudeUsage tracks session (five_hour) and week (seven_day) utilization and rejects invalid schema', () {
      final result = claudeUsage({
        'five_hour': {'utilization': 0, 'resets_at': '2026-10-01T16:00:00Z'},
        'seven_day': {'utilization': 96},
      })!;
      expect(result.authenticated, isTrue);
      expect(result.value, equals('4%'));
      expect(result.status, equals('warning'));
      expect(
        result.windows.map((w) => w.remainingPercent).toList(),
        equals([100.0, 4.0]),
      );

      for (final bad in [
        <String, dynamic>{},
        {'five_hour': {'utilization': 'NaN'}},
        {'five_hour': {'utilization': 150}},
        {'five_hour': {'utilization': -1}},
      ]) {
        expect(claudeUsage(bad), isNull);
      }
    });

    test('elapsed reset never grants capacity and shows "Reset fällig · aktualisieren"', () {
      final result = claudeUsage({
        'five_hour': {
          'utilization': 100,
          'resets_at': '2020-01-01T00:00:00Z',
        },
      })!;
      expect(
        resetLabel(result.windows[0]),
        equals('Reset fällig · aktualisieren'),
      );
      expect(result.windows[0].remainingPercent, equals(0.0));
    });

    test('pageUsage parses Claude and Gemini DOM text with German/English percentages', () {
      final claudePage = pageUsage(
        'Current session\n100% remaining\nResets in 2 hours\nAll models\nUsed: 95%\nResets in 3 days',
        'claude',
      )!;
      expect(
        claudePage.windows.map((w) => w.remainingPercent).toList(),
        equals([100.0, 5.0]),
      );

      final geminiPage = pageUsage(
        '5-hour usage\n80% left\nWeekly usage\n12,5% verbraucht',
        'gemini_chat',
      )!;
      expect(
        geminiPage.windows.map((w) => w.remainingPercent).toList(),
        equals([80.0, 87.5]),
      );

      final geminiGerman = pageUsage(
        'Nutzungslimits\nPRO\nAktuelle Nutzung\n0\u00a0% genutzt\nWird um 14:56 zurückgesetzt\n'
        'Wöchentliches Limit\nWird am 7. Okt. um 09:56 zurückgesetzt\n6\u00a0% genutzt',
        'gemini_chat',
      )!;
      expect(
        geminiGerman.windows.map((w) => w.remainingPercent).toList(),
        equals([100.0, 94.0]),
      );
    });

    test('geminiResetAt parses German and English reset strings across midnight and new year', () {
      final now = DateTime(2026, 12, 31, 23, 0);
      final fiveHourIso = geminiResetAt(
        'Wird um 02:15 zurückgesetzt',
        'five_hour',
        now,
      );
      expect(fiveHourIso, isNotNull);
      final parsed5h = DateTime.parse(fiveHourIso!).toLocal();
      expect(parsed5h.year, equals(2027));
      expect(parsed5h.month, equals(1));
      expect(parsed5h.day, equals(1));
      expect(parsed5h.hour, equals(2));
      expect(parsed5h.minute, equals(15));

      final englishWeekIso = geminiResetAt(
        'Resets on Jan 3 at 9:56 AM',
        'seven_day',
        now,
      );
      expect(englishWeekIso, isNotNull);
      final parsedWeek = DateTime.parse(englishWeekIso!).toLocal();
      expect(parsedWeek.year, equals(2027));
      expect(parsedWeek.month, equals(1));
      expect(parsedWeek.day, equals(3));
      expect(parsedWeek.hour, equals(9));
      expect(parsedWeek.minute, equals(56));

      for (final invalid in [
        'Wird um 25:99 zurückgesetzt',
        'Wird am 32. Okt. um 09:56 zurückgesetzt',
        'Wird am 7. Unknown um 09:56 zurückgesetzt',
        'Reset nicht verfügbar',
      ]) {
        expect(geminiResetAt(invalid, 'seven_day', now), isNull);
      }
    });
  });

  // =========================================================================
  // 3. DEPLETING RING MATH & STRICT COLOR LOGIC TESTS
  // =========================================================================
  group('3. DepletingRing Math & Strict Color Logic Tests', () {
    test('UsageWindow.remainingFraction == (1.0 - usedFraction).clamp(0.0, 1.0)', () {
      const fullWindow = UsageWindow(
        key: 'five_hour',
        title: '5 Stunden',
        usedPercent: 0.0,
      );
      expect(fullWindow.usedFraction, closeTo(0.0, 1e-6));
      expect(fullWindow.remainingFraction, closeTo(1.0, 1e-6));

      const partialWindow = UsageWindow(
        key: 'five_hour',
        title: '5 Stunden',
        usedPercent: 37.5,
      );
      expect(partialWindow.usedFraction, closeTo(0.375, 1e-6));
      expect(
        partialWindow.remainingFraction,
        closeTo((1.0 - partialWindow.usedFraction).clamp(0.0, 1.0), 1e-6),
      );

      const emptyWindow = UsageWindow(
        key: 'five_hour',
        title: '5 Stunden',
        usedPercent: 100.0,
      );
      expect(emptyWindow.usedFraction, closeTo(1.0, 1e-6));
      expect(emptyWindow.remainingFraction, closeTo(0.0, 1e-6));
      expect(emptyWindow.isExhausted, isTrue);
    });

    test('DepletingUsageRingPainter color is strictly neutral (#CBD5E1) > 10% and Signal Red (#FF2A2A) <= 10%', () {
      // 89% used -> 11% remaining (0.11 > 0.10) => Strictly Neutral (#CBD5E1)
      const painter11Percent = DepletingUsageRingPainter(
        remainingFraction: 0.11,
        hasData: true,
      );
      expect(
        painter11Percent.activeArcColor,
        equals(const Color(0xFFCBD5E1)),
      );
      expect(painter11Percent.activeArcColor, equals(AppConstants.ringNeutral));

      // 100% remaining (0% used) => Strictly Neutral (#CBD5E1)
      const painter100Percent = DepletingUsageRingPainter(
        remainingFraction: 1.0,
        hasData: true,
      );
      expect(
        painter100Percent.activeArcColor,
        equals(const Color(0xFFCBD5E1)),
      );

      // 90% used -> 10% remaining (0.10 <= 0.10) => Signal Red (#FF2A2A)
      const painter10Percent = DepletingUsageRingPainter(
        remainingFraction: 0.10,
        hasData: true,
      );
      expect(
        painter10Percent.activeArcColor,
        equals(const Color(0xFFFF2A2A)),
      );
      expect(
        painter10Percent.activeArcColor,
        equals(AppConstants.ringCritical),
      );

      // 95% used -> 5% remaining (0.05 <= 0.10) => Signal Red (#FF2A2A)
      const painter5Percent = DepletingUsageRingPainter(
        remainingFraction: 0.05,
        hasData: true,
      );
      expect(
        painter5Percent.activeArcColor,
        equals(const Color(0xFFFF2A2A)),
      );
    });
  });

  // =========================================================================
  // 4. NON-DESTRUCTIVE HOOK INSTALLER & HOOK SERVER TESTS
  // =========================================================================
  group('4. Non-Destructive Hook Installer & Hook Event Tests', () {
    test('HookInstallerService creates .bak backups and preserves existing user keys and custom hooks', () async {
      final tempHome = await Directory.systemTemp.createTemp('ampel_hooks_test_');
      try {
        final claudeDir = Directory(p.join(tempHome.path, '.claude'));
        final geminiConfigDir =
            Directory(p.join(tempHome.path, '.gemini', 'config'));
        final codexDir = Directory(p.join(tempHome.path, '.codex'));
        await claudeDir.create(recursive: true);
        await geminiConfigDir.create(recursive: true);
        await codexDir.create(recursive: true);

        final claudeSettingsFile = File(p.join(claudeDir.path, 'settings.json'));
        final initialClaudeJson = {
          'theme': 'dark',
          'customUserSetting': 42,
          'hooks': {
            'PreToolUse': [
              {
                'matcher': '*',
                'hooks': [
                  {'type': 'command', 'command': 'echo custom-user-hook'},
                ],
              },
            ],
          },
        };
        await claudeSettingsFile.writeAsString(jsonEncode(initialClaudeJson));

        final geminiHooksFile = File(p.join(geminiConfigDir.path, 'hooks.json'));
        await geminiHooksFile.writeAsString(
          jsonEncode({'userPreference': 'keep-me'}),
        );

        final codexHooksFile = File(p.join(codexDir.path, 'hooks.json'));
        await codexHooksFile.writeAsString(
          jsonEncode({'codexCustomFlag': true}),
        );

        final installer = HookInstallerService(customHomeDir: tempHome.path);
        final res = await installer.ensureHooksInstalled();

        expect(res.claudeInstalled, isTrue);
        expect(res.antigravityInstalled, isTrue);
        expect(res.codexInstalled, isTrue);
        expect(res.updatedFiles.length, equals(3));

        // Verify .bak files exist for all 3 configs
        expect(File('${claudeSettingsFile.path}.bak').existsSync(), isTrue);
        expect(File('${geminiHooksFile.path}.bak').existsSync(), isTrue);
        expect(File('${codexHooksFile.path}.bak').existsSync(), isTrue);

        // Verify existing user keys & custom hooks were preserved in ~/.claude/settings.json
        final mergedClaude = jsonDecode(await claudeSettingsFile.readAsString())
            as Map<String, dynamic>;
        expect(mergedClaude['theme'], equals('dark'));
        expect(mergedClaude['customUserSetting'], equals(42));
        final preToolUseStr = jsonEncode(mergedClaude['hooks']['PreToolUse']);
        expect(preToolUseStr, contains('echo custom-user-hook'));
        expect(preToolUseStr, contains('127.0.0.1:47832/api/hook'));

        // Verify Antigravity and Codex preserved user keys
        final mergedGemini = jsonDecode(await geminiHooksFile.readAsString())
            as Map<String, dynamic>;
        expect(mergedGemini['userPreference'], equals('keep-me'));
        expect(
          jsonEncode(mergedGemini['hooks']),
          contains('127.0.0.1:47832/api/hook'),
        );

        final mergedCodex = jsonDecode(await codexHooksFile.readAsString())
            as Map<String, dynamic>;
        expect(mergedCodex['codexCustomFlag'], isTrue);
        expect(
          jsonEncode(mergedCodex['hooks']),
          contains('127.0.0.1:47832/api/hook'),
        );
      } finally {
        await tempHome.delete(recursive: true);
      }
    });

    test('HookEventPayload and TrafficLightState transitions (Red, Yellow, Green, White)', () {
      // Chamber 3 (GREEN): working / PreToolUse
      final workEvent = HookEventPayload.parse({
        'agent': 'claude',
        'event': 'PreToolUse',
        'detail': 'Running bash',
      })!;
      expect(workEvent.agent, equals(AgentType.claude));
      expect(workEvent.targetState, equals(TrafficLightState.working));
      expect(workEvent.targetState.color, equals(AppConstants.ampelGreen));

      // Chamber 2 (YELLOW): permission / needsInput
      final permEvent = HookEventPayload.parse({
        'agent': 'antigravity',
        'event': 'permission_prompt',
        'detail': 'Wartet auf Bestätigung',
      })!;
      expect(permEvent.agent, equals(AgentType.antigravity));
      expect(permEvent.targetState, equals(TrafficLightState.needsInput));
      expect(permEvent.targetState.color, equals(AppConstants.ampelYellow));

      // Chamber 1 (RED): rate_limit / 429 / outOfUsage
      final errEvent = HookEventPayload.parse({
        'agent': 'codex',
        'event': 'error',
        'detail': 'HTTP 429 rate_limit reached',
      })!;
      expect(errEvent.agent, equals(AgentType.codex));
      expect(errEvent.targetState, equals(TrafficLightState.outOfUsage));
      expect(errEvent.isErrorEvent, isTrue);
      expect(errEvent.targetState.color, equals(AppConstants.ampelRed));

      // Chamber 4 (WHITE): stop / idle
      final stopEvent = HookEventPayload.parse({
        'agent': 'claude',
        'event': 'stop',
        'detail': 'Idle',
      })!;
      expect(stopEvent.targetState, equals(TrafficLightState.idle));
      expect(stopEvent.targetState.color, equals(AppConstants.ampelWhite));
    });
  });

  // =========================================================================
  // 5. AUTO-UPDATER SEMVER TESTS
  // =========================================================================
  group('5. Auto-Updater SemVer & GitHub Release Check Tests', () {
    test('compareSemVer and isNewerVersion handle v-prefixes, build numbers, and pre-releases', () {
      expect(AutoUpdaterService.normalizeVersion('v1.2.3+45'), equals('1.2.3'));
      expect(AutoUpdaterService.compareSemVer('v1.0.1', '1.0.0'), greaterThan(0));
      expect(AutoUpdaterService.compareSemVer('1.0.0', 'v1.0.0+1'), equals(0));
      expect(AutoUpdaterService.compareSemVer('2.0.0', '1.9.9'), greaterThan(0));
      expect(AutoUpdaterService.compareSemVer('1.0.0-beta.1', '1.0.0'), lessThan(0));

      expect(AutoUpdaterService.isNewerVersion('v1.1.0', '1.0.0'), isTrue);
      expect(AutoUpdaterService.isNewerVersion('v1.0.0', '1.0.0'), isFalse);
      expect(AutoUpdaterService.isNewerVersion('v0.9.5', '1.0.0'), isFalse);
    });

    test('AutoUpdaterService parses GitHub release response and exposes updateAvailable', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'tag_name': 'v2.4.0',
            'html_url': 'https://github.com/NairolfDev/TokenTracker/releases/tag/v2.4.0',
            'body': 'Release notes',
            'assets': [
              {
                'name': 'AgentAmpel-Windows-x64.zip',
                'browser_download_url':
                    'https://github.com/NairolfDev/TokenTracker/releases/download/v2.4.0/AgentAmpel-Windows-x64.zip',
              },
            ],
          }),
          200,
        );
      });

      final updater = AutoUpdaterService(
        httpClient: mockClient,
        autoStart: false,
      );
      final hasUpdate = await updater.checkForUpdates();
      expect(hasUpdate, isTrue);
      expect(updater.updateAvailable, isTrue);
      expect(updater.latestVersion, equals('2.4.0'));
      updater.dispose();
    });
  });

  // =========================================================================
  // 6. FULL HUD WIDGET & ANTIGRAVITY DRAWER EXPANSION TESTS
  // =========================================================================
  group('6. Full HUD Widget & Antigravity Drawer Expansion Tests', () {
    testWidgets('Wide window switches to the large layout without overflow', (tester) async {
      tester.view.physicalSize = const Size(920, 680);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controller = AmpelController(
        autoUpdaterService: AutoUpdaterService(
          httpClient: MockClient((_) async => http.Response('{"tag_name":"v1.0.0"}', 200)),
          autoStart: false,
        ),
      );
      addTearDown(controller.dispose);
      await controller.setDemoMode(true);

      await tester.pumpWidget(MaterialApp(home: AmpelHudScreen(controller: controller)));
      await tester.pumpAndSettle();

      expect(find.byType(AntigravityLimitsDrawer), findsOneWidget);
      expect(find.textContaining('▾ Alle'), findsNothing); // drawer is always open, no pill
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Renders all 3 rows (Codex, Antigravity, Claude), 4-chamber TrafficLightWidgets, DepletingUsageRings, and expands Antigravity drawer with 0 overflows',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(420, 500);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final mockHttp = MockClient(
          (_) async => http.Response('{"tag_name":"v1.0.0"}', 200),
        );
        final controller = AmpelController(
          autoUpdaterService: AutoUpdaterService(
            httpClient: mockHttp,
            autoStart: false,
          ),
        );
        addTearDown(controller.dispose);

        // Populate rich Demo Mode quotas including 6 Antigravity sub-limits
        await controller.setDemoMode(true);

        await tester.pumpWidget(
          MaterialApp(
            home: AmpelHudScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        // Verify all 3 Agent rows are rendered
        expect(find.text('OpenAI Codex'), findsOneWidget);
        expect(find.text('Google Antigravity'), findsOneWidget);
        expect(find.text('Claude Code'), findsOneWidget);

        // Verify 3 AgentLogoWidgets and 3 TrafficLightWidgets (4 chambers each)
        expect(find.byType(AgentLogoWidget), findsNWidgets(3));
        expect(find.byType(TrafficLightWidget), findsNWidgets(3));
        expect(find.byType(DepletingUsageRing), findsWidgets);

        // Verify the Antigravity expand pill (`▾ Alle (6)`) is present and tap it
        final expandPill = find.textContaining('▾ Alle');
        expect(expandPill, findsOneWidget);

        await tester.tap(expandPill);
        await tester.pumpAndSettle();

        expect(controller.isAntigravityExpanded, isTrue);
        expect(find.byType(AntigravityLimitsDrawer), findsOneWidget);
        expect(find.textContaining('▴ Alle'), findsOneWidget);
        expect(
          find.textContaining('Google Antigravity · Alle Modell- & Zeitfenster-Kontingente'),
          findsOneWidget,
        );

        // Verify sub-limits inside drawer are visible with zero RenderFlex overflow exceptions
        expect(find.textContaining('Gemini 2.5 Pro'), findsOneWidget);
        expect(find.textContaining('Claude Sonnet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

void customAgentAndArgonTests() {
  group('7. Custom agents & Antigravity extra weekly-only limit', () {
    test('hook payload for unknown agent becomes a custom agent with usage', () {
      final e = HookEventPayload.parse({
        'agent': 'Kimi K2',
        'event': 'working',
        'usage': {'5h': 40, 'Woche': 250},
      })!;
      expect(e.agent, AgentType.custom);
      expect(e.customId, 'kimi-k2');
      expect(e.usage, {'5h': 40.0});
    });

    test('CustomAgent limits parse label=percent pairs', () {
      final w = CustomAgent.parseLimits('5h=40, Woche=12, Leer');
      expect(w.map((x) => x.key), ['5h', 'woche', 'leer']);
      expect(w[0].usedPercent, 40.0);
      expect(w[2].usedPercent, isNull);
    });

    test('unlabeled weekly-only bucket (Argon) is kept as its own sub-limit', () {
      final payload = _antigravityFixtureQuotas();
      ((payload['response']['groups'] as List)[0]['buckets'] as List).add({
        'bucketId': 'gemini-4-argon-weekly',
        'remainingFraction': 0.5,
        'resetTime': '2030-10-02T17:45:10Z',
      });
      final result = antigravityUsage(payload)!;
      expect(result.windows.length, 4);
      expect(result.subLimits.length, 5);
      expect(result.subLimits.last.group, 'gemini 4 argon');
      expect(result.subLimits.last.title, 'Woche');
      expect(result.subLimits.last.remainingPercent, 50.0);
    });
  });
}

void claudePlanUsageTest() {
  test('Claude plan usage comes from the oauth usage endpoint, not token estimates', () async {
    final tmp = await Directory.systemTemp.createTemp('claude_home_');
    addTearDown(() => tmp.delete(recursive: true));
    final claudeDir = Directory(p.join(tmp.path, '.claude'))..createSync();
    File(p.join(claudeDir.path, '.credentials.json')).writeAsStringSync(jsonEncode({
      'claudeAiOauth': {
        'accessToken': 'test-token',
        'expiresAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      },
    }));
    final client = MockClient((req) async {
      expect(req.headers['Authorization'], 'Bearer test-token');
      return http.Response(
        jsonEncode({
          'five_hour': {'utilization': 17.0, 'resets_at': '2030-01-01T10:00:00Z'},
          'seven_day': {'utilization': 10.0, 'resets_at': '2030-01-04T08:00:00Z'},
        }),
        200,
      );
    });
    final stats = await ClaudeUsageService(httpClient: client).checkLive(claudeDir.path);
    expect(stats, isNotNull);
    expect(stats!.authenticated, isTrue);
    expect(stats.windows.map((w) => w.usedPercent), [17.0, 10.0]);
  });
}
