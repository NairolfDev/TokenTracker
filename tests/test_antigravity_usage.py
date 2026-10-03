"""Antigravity's own schema: separate pools, explicit fractions, local read-only RPC."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

import requests

from antigravity_usage import (AntigravityUsageClient, LocalServer, QUOTA_METHOD,
                              antigravity_usage, servers_from_processes)
from manager import ConnectionManager
from usage_cache import UsageCache


def quotas():
    return {'response': {'groups': [
        {'displayName': 'Gemini Models', 'buckets': [
            {'bucketId': 'gemini-weekly', 'window': 'weekly', 'remainingFraction': .33, 'resetTime': '2030-10-09T07:55:59Z'},
            {'bucketId': 'gemini-5h', 'window': '5h', 'remainingFraction': .76, 'resetTime': '2030-10-02T17:45:10Z'}]},
        {'displayName': 'Claude and GPT models', 'buckets': [
            {'bucketId': '3p-weekly', 'window': 'weekly', 'remainingFraction': .9, 'resetTime': '2030-10-09T12:45:10Z'},
            {'bucketId': '3p-5h', 'window': '5h', 'remainingFraction': .12, 'resetTime': '2030-10-02T17:45:10Z'}]},
    ]}}


class AntigravityParsingTests(unittest.TestCase):
    def test_distinct_model_pools_and_durations(self):
        result = antigravity_usage(quotas())
        self.assertTrue(result.authenticated)
        self.assertEqual([w.remaining_percent for w in result.windows], [76, 33, 12, 90])
        self.assertEqual([w.group for w in result.windows], ['Gemini', 'Gemini', 'Claude / GPT', 'Claude / GPT'])
        self.assertEqual(result.label, 'Claude / GPT · 5 Stunden übrig')
        self.assertEqual(result.value, '12%')
        self.assertEqual(result.windows[1].resets_at, '2030-10-09T07:55:59+00:00')

    def test_zero_is_exhausted_and_one_is_full(self):
        payload = quotas()
        payload['response']['groups'][0]['buckets'][0]['remainingFraction'] = 0
        payload['response']['groups'][0]['buckets'][1]['remainingFraction'] = 1
        result = antigravity_usage(payload)
        self.assertEqual(result.windows[0].remaining_percent, 100)
        self.assertEqual(result.windows[1].remaining_percent, 0)
        self.assertEqual(result.status, 'warning')

    def test_missing_or_credit_amount_is_unknown(self):
        payload = quotas()
        row = payload['response']['groups'][0]['buckets'][1]
        row.pop('remainingFraction')
        row['remainingAmount'] = '300'
        result = antigravity_usage(payload)
        self.assertIsNone(result.windows[0].remaining_percent)
        self.assertEqual(result.windows[1].remaining_percent, 33)

    def test_invalid_fractions_are_not_capacity(self):
        for bad in (True, -1, 1.2, float('nan'), None, {}):
            with self.subTest(bad=bad):
                payload = {'response': {'buckets': [{'bucketId': 'gemini-5h', 'window': '5h', 'remainingFraction': bad}]}}
                self.assertIsNone(antigravity_usage(payload))

    def test_disabled_bucket_is_not_full_capacity(self):
        payload = quotas()
        payload['response']['groups'][1]['buckets'][1]['disabled'] = True
        result = antigravity_usage(payload)
        self.assertIsNone(result.windows[2].remaining_percent)
        self.assertTrue(result.windows[2].disabled)
        self.assertEqual(result.value, '33%')

    def test_unknown_or_contradictory_window_is_ignored(self):
        for row in ({'bucketId': 'unknown-5h', 'window': '5h', 'remainingFraction': 1},
                    {'bucketId': 'gemini-5h', 'window': 'weekly', 'remainingFraction': 1}):
            self.assertIsNone(antigravity_usage({'response': {'buckets': [row]}}))

    def test_conflicting_duplicate_is_unknown(self):
        payload = quotas()
        payload['response']['buckets'] = [{'bucketId': 'gemini-5h', 'window': '5h', 'remainingFraction': 1}]
        self.assertIsNone(antigravity_usage(payload).windows[0].remaining_percent)

    def test_unrecognized_shapes_and_reset_remain_unknown(self):
        for payload in (None, [], {}, {'response': []}, {'response': {'groups': 'not a list'}}):
            self.assertIsNone(antigravity_usage(payload))
        payload = quotas()
        payload['response']['groups'][0]['buckets'][0]['resetTime'] = 'today'
        self.assertIsNone(antigravity_usage(payload).windows[1].resets_at)

    def test_cache_keeps_groups_and_does_not_keep_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = UsageCache(Path(directory) / 'usage.json')
            cache.put('antigravity', antigravity_usage(quotas()))
            data = json.loads(cache.path.read_text(encoding='utf-8'))
            self.assertEqual(len(data['providers']['antigravity']['windows']), 4)
            restored = cache.load()['antigravity']
            self.assertTrue(restored.stale)
            self.assertFalse(restored.authenticated)
            self.assertEqual([w.remaining_percent for w in restored.windows], [76, 33, 12, 90])
            self.assertEqual(restored.windows[2].group, 'Claude / GPT')
            self.assertNotIn('csrf', cache.path.read_text(encoding='utf-8'))


class LocalDiscoveryTests(unittest.TestCase):
    def test_only_antigravity_process_and_owned_ports(self):
        rows = [dict(ProcessId=42, ExecutablePath=r'C:\Users\test\Programs\Antigravity\resources\bin\language_server.exe',
                     CommandLine='server --override_ide_name antigravity --csrf_token "local-test-token" --https_server_port 0'),
                dict(ProcessId=99, ExecutablePath=r'C:\Programs\Windsurf\resources\bin\language_server.exe',
                     CommandLine='server --override_ide_name antigravity --csrf_token foreign-token')]
        ports = (' TCP 127.0.0.1:61454 0.0.0.0:0 LISTENING 42\n'
                 ' TCP 127.0.0.1:61454 127.0.0.1:99 ESTABLISHED 42\n'
                 ' TCP 127.0.0.1:7777 0.0.0.0:0 LISTENING 99\n')
        servers = servers_from_processes(rows, ports)
        self.assertEqual(servers, [LocalServer(42, 61454, 'local-test-token')])
        self.assertNotIn('local-test-token', repr(servers))
        rows[0]['CommandLine'] = 'server --override_ide_name windsurf --csrf_token local-test-token'
        self.assertEqual(servers_from_processes(rows, ports), [])


class AntigravityClientTests(unittest.TestCase):
    def client(self, payload=None, status=200):
        session = Mock()
        session.__enter__ = Mock(return_value=session)
        session.__exit__ = Mock(return_value=False)
        response = Mock(status_code=status, content=b'{}')
        response.json.return_value = payload if payload is not None else quotas()
        session.post.return_value = response
        client = AntigravityUsageClient(lambda: [LocalServer(42, 12345, 'local-test-token')], lambda: session)
        return client, session

    def test_only_read_only_loopback_quota_rpc_no_redirects_or_proxy(self):
        client, session = self.client()
        self.assertTrue(client.check().authenticated)
        args, options = session.post.call_args
        self.assertEqual(args, ('https://127.0.0.1:12345' + QUOTA_METHOD,))
        self.assertEqual(options['json'], {'forceRefresh': True})
        self.assertFalse(options['allow_redirects'])
        self.assertFalse(session.trust_env)
        self.assertEqual(session.post.call_count, 1)

    def test_closed_app_is_paused_and_never_authenticates(self):
        session_factory = Mock()
        result = AntigravityUsageClient(lambda: [], session_factory).check()
        self.assertEqual(result.status, 'paused')
        self.assertFalse(result.authenticated)
        self.assertEqual(len(result.windows), 4)
        session_factory.assert_not_called()

    def test_failures_do_not_expose_server_secrets_or_invent_capacity(self):
        for status in (302, 401, 500):
            client, session = self.client(status=status)
            result = client.check()
            self.assertFalse(result.authenticated)
            self.assertTrue(all(w.remaining_percent is None for w in result.windows))
            self.assertNotIn('local-test-token', repr(result))
        client, session = self.client()
        session.post.side_effect = requests.Timeout('private transport details')
        self.assertNotIn('private', client.check().detail)

    def test_unknown_schema_reports_error(self):
        client, session = self.client(payload={'response': {'remainingFraction': 1}})
        result = client.check()
        self.assertEqual(result.status, 'error')
        self.assertFalse(result.authenticated)

    def test_manager_uses_local_client_and_disconnect_preserves_app_login(self):
        vault, browsers, local = Mock(), Mock(), Mock()
        local.check.return_value = antigravity_usage(quotas())
        manager = ConnectionManager(vault=vault, browsers=browsers, antigravity=local)
        try:
            self.assertTrue(manager.connect_antigravity())
            pid, op, result = manager.events.get(timeout=3)
            self.assertEqual((pid, op), ('antigravity', 'connect'))
            self.assertTrue(result.authenticated)
            self.assertTrue(manager.refresh('antigravity'))
            manager.events.get(timeout=3)
            self.assertEqual(local.check.call_count, 2)
            self.assertTrue(manager.disconnect('antigravity'))
            self.assertEqual(manager.events.get(timeout=3)[2].status, 'disconnected')
            vault.delete.assert_not_called()
            vault.get.assert_not_called()
            browsers.forget.assert_not_called()
        finally:
            manager.shutdown()


if __name__ == '__main__':
    unittest.main()
