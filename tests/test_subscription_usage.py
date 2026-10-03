import json
from datetime import datetime, timezone
from pathlib import Path
import queue
import tempfile
import unittest
from unittest.mock import Mock
from types import SimpleNamespace

from api_clients import ProviderStats
from codex_usage import CodexUsageClient
from manager import ConnectionManager
from observed_usage import claude_usage
from subscription_usage import codex_usage, page_usage, reset_label
from usage_cache import UsageCache
from browser_sessions import BrowserSessions
from subscription_usage import empty_quota


def fixture(primary=35, secondary=90):
    return {'rateLimits': {'limitId': 'codex',
            'primary': {'usedPercent': primary, 'windowDurationMins': 300, 'resetsAt': 1900000000},
            'secondary': {'usedPercent': secondary, 'windowDurationMins': 10080, 'resetsAt': 1900500000}}}


class SubscriptionTests(unittest.TestCase):
    def test_independent_capacity_and_resets_not_primary_only(self):
        result = codex_usage(fixture(0, 100))
        self.assertEqual([w.remaining_percent for w in result.windows], [100, 0])
        self.assertEqual(result.value, '0%')
        self.assertEqual(result.label, 'Woche übrig')
        self.assertEqual(result.status, 'warning')
        self.assertNotEqual(result.windows[0].resets_at, result.windows[1].resets_at)

    def test_window_duration_defines_five_hour_and_week(self):
        payload = fixture()
        snapshot = payload['rateLimits']
        snapshot['primary'], snapshot['secondary'] = snapshot['secondary'], snapshot['primary']
        self.assertEqual([w.remaining_percent for w in codex_usage(payload).windows], [65, 10])

    def test_codex_bucket_wins_over_other_model_limits(self):
        payload = fixture(99, 99)
        payload['rateLimitsByLimitId'] = {'codex': fixture(25, 60)['rateLimits'], 'other': fixture(100, 100)['rateLimits']}
        self.assertEqual([w.remaining_percent for w in codex_usage(payload).windows], [75, 40])
        self.assertIsNone(codex_usage({'rateLimits': {'limitId': 'other', 'primary': fixture()['rateLimits']['primary']}}))

    def test_missing_or_invalid_window_is_unknown_not_unlimited(self):
        for value in (None, True, 'NaN', -1, 101, {}, []):
            result = codex_usage(fixture(value, 40))
            self.assertIsNone(result.windows[0].remaining_percent)
            self.assertEqual(result.windows[1].remaining_percent, 60)
        payload = fixture()
        payload['rateLimits']['primary'] = None
        self.assertIsNone(codex_usage(payload).windows[0].remaining_percent)
        payload['rateLimits']['secondary']['windowDurationMins'] = 60
        self.assertIsNone(codex_usage(payload))

    def test_separate_claude_sections_and_remaining_direction(self):
        result = page_usage('Current session\n100% remaining\nResets in 2 hours\nAll models\nUsed: 95%\nResets in 3 days', 'claude')
        self.assertEqual([w.remaining_percent for w in result.windows], [100, 5])
        resets = [datetime.fromisoformat(w.resets_at) for w in result.windows]
        self.assertGreater((resets[1] - resets[0]).total_seconds(), 2 * 86400)
        self.assertIsNone(page_usage('Current session\nunknown\nAll models\n20% used', 'claude').windows[0].remaining_percent)

    def test_gemini_sections_and_german_decimal_percentages(self):
        result = page_usage('5-hour usage\n80% left\nWeekly usage\n12,5% verbraucht', 'gemini_chat')
        self.assertEqual([w.remaining_percent for w in result.windows], [80, 87.5])
        self.assertIsNone(page_usage('5-hour\n80%\nWeekly\n12%', 'gemini_chat'))

    def test_elapsed_reset_never_grants_capacity(self):
        result = claude_usage({'five_hour': {'utilization': 100, 'resets_at': '2020-01-01T00:00:00Z'}})
        self.assertEqual(reset_label(result.windows[0]), 'Reset fällig · aktualisieren')
        self.assertEqual(result.windows[0].remaining_percent, 0)

    def test_claude_redirecting_document_does_not_abort_delayed_quota(self):
        page = Mock(url='https://claude.ai/settings/usage')
        page.is_closed.return_value = False
        page.locator.return_value.inner_text.side_effect = TimeoutError
        evidence = SimpleNamespace(observed_at=0, authenticated=None, usage=None)
        session = SimpleNamespace(evidence={page: evidence})
        pumps = []
        def pump(*args):
            pumps.append(True)
            if len(pumps) == 2:
                evidence.observed_at, evidence.authenticated = 1, True
                evidence.usage = claude_usage({'five_hour': {'utilization': 0}, 'seven_day': {'utilization': 95}})
        page.wait_for_timeout.side_effect = pump
        result = BrowserSessions()._wait_claude_quota(session, page, empty_quota('Claude-Abo', authenticated=True))
        self.assertEqual([w.remaining_percent for w in result.windows], [100, 5])
        self.assertEqual(len(pumps), 2)


class FakeStdout:
    def __init__(self):
        self.lines = queue.Queue()

    def __iter__(self):
        while (line := self.lines.get()) is not None:
            yield line

    def close(self):
        self.lines.put(None)


class FakeProcess:
    def __init__(self, account=True, fail=False):
        self.stdout = FakeStdout()
        self.stdin = Mock(write=self.write, flush=lambda: None, close=self.stdout.close)
        self.sent = []
        self.account, self.fail = account, fail
        self.wait = Mock(return_value=0)
        self.terminate, self.kill = Mock(), Mock()

    def write(self, line):
        message = json.loads(line)
        self.sent.append(message)
        if 'id' not in message:
            return
        method = message['method']
        result = {} if method == 'initialize' else {'account': {'type': 'chatgpt', 'planType': 'plus', 'email': 'fixture-private'}} if method == 'account/read' and self.account else {'account': None} if method == 'account/read' else fixture()
        response = {'id': message['id'], 'result': result}
        if self.fail:
            response = {'id': message['id'], 'error': {'message': 'fixture-secret-must-not-leak'}}
        self.stdout.lines.put('not json\n')
        self.stdout.lines.put(json.dumps({'method': 'account/updated', 'params': {}}) + '\n')
        self.stdout.lines.put(json.dumps(response) + '\n')


class CodexProtocolTests(unittest.TestCase):
    def test_only_documented_read_operations_no_tokens_or_logout(self):
        process = FakeProcess()
        factory = Mock(return_value=process)
        stats = CodexUsageClient(binary='fixture-codex', factory=factory).check()
        self.assertTrue(stats.authenticated)
        self.assertEqual([m['method'] for m in process.sent], ['initialize', 'initialized', 'account/read', 'account/rateLimits/read'])
        self.assertEqual(process.sent[2]['params'], {'refreshToken': False})
        self.assertNotIn('fixture-private', repr(stats))
        self.assertIn('Plus', stats.source)
        process.wait.assert_called_once()
        process.terminate.assert_not_called()

    def test_no_codex_subscription_login_does_not_read_quotas(self):
        process = FakeProcess(account=False)
        result = CodexUsageClient(binary='fixture', factory=lambda *a, **k: process).check()
        self.assertEqual(result.status, 'unauthorized')
        self.assertEqual([m['method'] for m in process.sent], ['initialize', 'initialized', 'account/read'])

    def test_rpc_errors_are_sanitized(self):
        result = CodexUsageClient(binary='fixture', factory=lambda *a, **k: FakeProcess(fail=True)).check()
        self.assertEqual(result.status, 'error')
        self.assertNotIn('fixture-secret', repr(result))

    def test_manager_uses_codex_without_browser_or_vault(self):
        vault, browsers = Mock(), Mock()
        codex = Mock(check=lambda: codex_usage(fixture()))
        manager = ConnectionManager(vault, browsers, codex)
        try:
            manager.refresh('chatgpt')
            self.assertTrue(manager.events.get(timeout=2)[2].authenticated)
            manager.disconnect('chatgpt')
            self.assertEqual(manager.events.get(timeout=2)[2].status, 'disconnected')
            vault.get.assert_not_called()
            vault.delete.assert_not_called()
            browsers.check.assert_not_called()
            browsers.forget.assert_not_called()
        finally:
            manager.shutdown()


class CacheTests(unittest.TestCase):
    def test_restart_retains_measured_windows_but_does_not_authenticate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'usage.json'
            cache = UsageCache(path)
            measured = codex_usage(fixture())
            cache.put('chatgpt', measured)
            loaded = UsageCache(path).load()['chatgpt']
            self.assertEqual([w.remaining_percent for w in loaded.windows], [65, 10])
            self.assertEqual(loaded.checked_at, measured.checked_at)
            self.assertTrue(loaded.stale)
            self.assertFalse(loaded.authenticated)
            data = json.loads(path.read_text())['providers']['chatgpt']
            self.assertEqual(set(data), {'checked_at', 'source', 'windows'})
            cache.put('chatgpt', ProviderStats(authenticated=True))
            cache.put('chatgpt', loaded)
            self.assertEqual(UsageCache(path).load()['chatgpt'].checked_at, measured.checked_at)
            cache.delete('chatgpt')
            self.assertNotIn('chatgpt', UsageCache(path).load())

    def test_corrupt_unknown_and_invalid_cached_windows_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'usage.json'
            path.write_text('{broken')
            self.assertEqual(UsageCache(path).load(), {})
            row = {'checked_at': datetime.now(timezone.utc).isoformat(), 'windows': {'five_hour': {'used_percent': 'NaN'}}}
            path.write_text(json.dumps({'version': 1, 'providers': {'chatgpt': row, 'unknown': row}}))
            self.assertEqual(UsageCache(path).load(), {})


if __name__ == '__main__':
    unittest.main()
