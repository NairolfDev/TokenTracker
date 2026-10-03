import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

import requests

from api_clients import ProviderStats, check_api
from browser_sessions import BrowserError, BrowserSessions, authenticated_evidence, extract_usage
from manager import ConnectionManager
from openrouter_auth import AuthError, OpenRouterLogin, pkce_pair
from providers import PROVIDERS
from storage import CredentialVault, SettingsStore, StorageError, defaults
from single_instance import InstanceGuard


class ProviderApiTests(unittest.TestCase):
    def client(self, data, code=200):
        return Mock(get=Mock(return_value=Mock(status_code=code, json=Mock(return_value=data))))

    def test_key_budget_does_not_claim_account_is_unlimited(self):
        result = check_api("openrouter", "fake-key", self.client({"data": {"usage": 1.25, "limit": None}}))
        self.assertTrue(result.authenticated)
        self.assertEqual(result.value, "$1.2500")
        self.assertNotIn("unlimitiert", result.value.lower())
        self.assertEqual(result.metrics[1][1], "Nicht verfügbar")

    def test_openrouter_zero_and_exhausted_limits(self):
        for limit, usage in ((0, 0), (5, 8)):
            with self.subTest(limit=limit):
                result = check_api("openrouter", "fake-key", self.client({"data": {"usage": usage, "limit": limit}}))
                self.assertEqual(result.value, "$0.00")
                self.assertEqual(result.progress, 1)

    def test_invalid_numbers_and_schema_are_not_connected(self):
        for data in ({"data": {"usage": "nan"}}, {"data": {"usage": -1}}, {}, [], {"data": None}):
            self.assertFalse(check_api("openrouter", "fake-key", self.client(data)).authenticated)

    def test_zero_deepseek_balance_is_a_valid_login(self):
        result = check_api("deepseek_api", "fake-key", self.client({"is_available": False,
                           "balance_infos": [{"currency": "USD", "total_balance": "0.00"}]}))
        self.assertTrue(result.authenticated)
        self.assertEqual(result.status, "warning")

    def test_http_errors_never_confirm_a_connection(self):
        for code in (401, 403, 429, 500, 302):
            result = check_api("openrouter", "fake-key", self.client({}, code))
            self.assertFalse(result.authenticated)
        self.assertEqual(check_api("openrouter", "fake-key", self.client({}, 401)).status, "unauthorized")
        self.assertEqual(check_api("openrouter", "fake-key", self.client({}, 403)).status, "error")

    def test_model_connections_use_correct_auth_headers(self):
        for pid in ("openai_api", "groq", "mistral_api", "anthropic_api", "gemini_api"):
            with self.subTest(provider=pid):
                client = self.client({"models" if pid == "gemini_api" else "data": [{"id": "model"}]})
                self.assertTrue(check_api(pid, "fake-key", client).authenticated)
                kwargs = client.get.call_args.kwargs
                self.assertFalse(kwargs["allow_redirects"])
                if pid == "anthropic_api":
                    self.assertEqual(kwargs["headers"]["x-api-key"], "fake-key")
                elif pid == "gemini_api":
                    self.assertEqual(kwargs["headers"]["x-goog-api-key"], "fake-key")
                else:
                    self.assertEqual(kwargs["headers"]["Authorization"], "Bearer fake-key")

    def test_timeout_is_retryable_not_logged_out(self):
        client = Mock(get=Mock(side_effect=requests.Timeout))
        result = check_api("openrouter", "fake-key", client)
        self.assertEqual(result.status, "error")
        self.assertFalse(result.authenticated)

    def test_models_list_is_not_reported_as_token_tracking(self):
        for pid in ("openai_api", "groq", "mistral_api", "anthropic_api", "gemini_api"):
            result = check_api(pid, "fixture", self.client({"models" if pid == "gemini_api" else "data": []}))
            self.assertTrue(result.authenticated)
            self.assertEqual(result.label, "Kein Tokenzähler verfügbar")
            self.assertIn(("Tokenverbrauch", "Nicht abrufbar"), result.metrics)

    def test_invalid_gemini_key_is_not_treated_as_network_failure(self):
        client = self.client({"error": {"details": [{"reason": "API_KEY_INVALID"}]}}, 400)
        self.assertEqual(check_api("gemini_api", "fixture", client).status, "unauthorized")

    def test_weekly_claude_counter_is_not_labeled_as_session(self):
        result = extract_usage("All models\n92% used", "claude")
        self.assertEqual(result.label, "Woche übrig")
        self.assertEqual(result.value, "8%")


class BrowserEvidenceTests(unittest.TestCase):
    def cookie(self, name="sessionKey", domain=".claude.ai", expires=-1):
        return {"name": name, "domain": domain, "value": "fixture", "expires": expires}

    def test_provider_name_and_guest_composer_are_not_login(self):
        self.assertFalse(authenticated_evidence(PROVIDERS["claude"], "https://claude.ai", [], False))
        self.assertFalse(authenticated_evidence(PROVIDERS["claude"], "https://claude.ai", [self.cookie()], False))

    def test_authenticated_account_and_cookie_required(self):
        self.assertTrue(authenticated_evidence(PROVIDERS["claude"], "https://claude.ai/settings/usage", [self.cookie()], True))

    def test_chunked_chatgpt_session_is_recognized(self):
        cookies = [self.cookie('__Secure-next-auth.session-token.' + str(i), '.chatgpt.com') for i in (0, 1)]
        self.assertTrue(authenticated_evidence(PROVIDERS['chatgpt'], 'https://chatgpt.com', cookies, True))

    def test_expired_and_foreign_domain_cookies_are_rejected(self):
        for cookie in (self.cookie(expires=time.time()-100), self.cookie(domain="claude.ai.evil.example")):
            self.assertFalse(authenticated_evidence(PROVIDERS["claude"], "https://claude.ai", [cookie], True))
        self.assertFalse(authenticated_evidence(PROVIDERS["claude"], "https://claude.ai.evil.example", [self.cookie()], True))

    def test_login_route_and_google_auth_redirect_are_not_connected(self):
        self.assertFalse(authenticated_evidence(PROVIDERS["claude"], "https://claude.ai/login", [self.cookie()], True))
        self.assertFalse(authenticated_evidence(PROVIDERS["chatgpt"], "https://accounts.google.com", [], False))

    def test_google_cookie_without_account_control_is_not_login(self):
        self.assertFalse(authenticated_evidence(PROVIDERS["gemini"], "https://aistudio.google.com", [self.cookie("SID", ".google.com")], False))

    def test_each_browser_provider_requires_authenticated_evidence_on_its_product(self):
        for provider in PROVIDERS.values():
            if provider.kind != "browser":
                continue
            with self.subTest(provider=provider.id):
                cookie = self.cookie(provider.session_cookies[0], provider.domains[0])
                self.assertTrue(authenticated_evidence(provider, provider.url, [cookie], True))
                self.assertFalse(authenticated_evidence(provider, provider.url, [cookie], False))
                self.assertFalse(authenticated_evidence(provider, provider.url, [], True))
                self.assertFalse(authenticated_evidence(provider, "https://accounts.google.com/login", [cookie], True))

    def test_unknown_limit_is_not_unlimited(self):
        result = extract_usage("Welcome to ChatGPT", "chatgpt")
        self.assertTrue(result.authenticated)
        self.assertEqual(result.metrics[0], ("Nutzungslimit", "Nicht verfügbar"))

    def test_claude_quota_is_bound_to_current_usage_section(self):
        self.assertIsNone(extract_usage("an example with 75% used", "claude").progress)
        result = extract_usage("Current session\nResets in 2 hours\n75% used", "claude")
        self.assertEqual(result.progress, .25)


class BrowserCloseTests(unittest.TestCase):
    def test_shutdown_detaches_reattached_windows_and_closes_only_own_processes(self):
        sessions = BrowserSessions()
        attached = Mock(process=None)
        owned = Mock(process=Mock())
        sessions.sessions = {'claude': attached, 'gemini_chat': owned}
        sessions.playwright = Mock()
        engine = sessions.playwright
        with patch.object(sessions, 'close') as close, patch.object(sessions, '_request_close') as request_close:
            sessions.shutdown()
            close.assert_called_once_with('gemini_chat')
            request_close.assert_not_called()
        attached.browser.close.assert_called_once()
        engine.stop.assert_called_once()

    def test_forget_can_close_an_existing_profile_without_attaching_or_launching(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / 'claude'
            profile.mkdir()
            (profile / 'fixture').write_text('test data')
            sessions = BrowserSessions(root)
            with patch.object(sessions, '_endpoint', side_effect=['http://127.0.0.1:9222', None, None]), \
                    patch.object(sessions, '_request_close') as close, \
                    patch.object(sessions, '_open', side_effect=AssertionError('Disconnect started browser')):
                sessions.forget('claude')
                close.assert_called_once_with(profile.resolve())
            self.assertFalse(profile.exists())

    def test_forget_rejects_paths_outside_provider_profiles_before_any_browser_action(self):
        with tempfile.TemporaryDirectory() as directory:
            sessions = BrowserSessions(Path(directory) / 'profiles')
            with patch.object(sessions, '_endpoint') as endpoint, patch.object(sessions, 'close') as close:
                with self.assertRaises(BrowserError):
                    sessions.forget('../outside')
                endpoint.assert_not_called()
                close.assert_not_called()

    def test_close_cannot_target_foreign_browser_and_never_waits_for_command_reply(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            (profile / "DevToolsActivePort").write_text("9222\n/devtools/browser/fixture\n")
            sessions = BrowserSessions(profile)
            connection = Mock()
            for target, allowed in (("ws://127.0.0.1:9222/devtools/browser/fixture", True),
                                    ("ws://evil.example:9222/devtools/browser/fixture", False),
                                    ("ws://127.0.0.1:9223/devtools/browser/fixture", False),
                                    ("ws://127.0.0.1:9222/devtools/browser/different", False)):
                with self.subTest(target=target), patch.object(sessions, "_endpoint", return_value="http://127.0.0.1:9222"), \
                        patch("browser_sessions.requests.get", return_value=Mock(json=lambda: {"webSocketDebuggerUrl": target})), \
                        patch("websocket.create_connection", return_value=connection) as connect:
                    if allowed:
                        sessions._request_close(profile)
                        self.assertLessEqual(connect.call_args.kwargs["timeout"], 2)
                        self.assertEqual(json.loads(connection.send.call_args.args[0])["method"], "Browser.close")
                        connection.recv.assert_not_called()
                    else:
                        with self.assertRaises(BrowserError):
                            sessions._request_close(profile)
                        connect.assert_not_called()


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def test_only_enabled_and_connected_providers_visible(self):
        store = SettingsStore(self.root / "config.json", vault=Mock())
        self.assertEqual(store.visible(), [])
        store.data["providers"]["claude"]["connected"] = True
        self.assertEqual(store.visible(), ["claude"])
        store.data["providers"]["claude"]["enabled"] = False
        self.assertEqual(store.visible(), [])

    def test_legacy_key_migrates_before_plaintext_is_removed(self):
        path = self.root / "config.json"
        path.write_text(json.dumps({"openrouter_key": "fake-migration-key", "refresh_minutes": "5"}))
        vault = Mock()
        store = SettingsStore(path, vault)
        vault.set.assert_called_once_with("openrouter", "fake-migration-key")
        self.assertNotIn("fake-migration-key", path.read_text())
        self.assertFalse(store.data["providers"]["openrouter"]["connected"])

    def test_failed_migration_preserves_original(self):
        path = self.root / "config.json"
        original = '{"openrouter_key":"fake-key"}'
        path.write_text(original)
        store = SettingsStore(path, Mock(set=Mock(side_effect=StorageError("failed"))))
        with self.assertRaises(StorageError):
            store.save()
        self.assertEqual(path.read_text(), original)

    def test_bad_config_is_not_silently_overwritten(self):
        path = self.root / "config.json"
        path.write_text("{broken")
        store = SettingsStore(path, Mock())
        with self.assertRaises(StorageError):
            store.save()
        self.assertEqual(path.read_text(), "{broken")

    @unittest.skipUnless(os.name == "nt", "Windows DPAPI")
    def test_windows_vault_roundtrip_never_stores_plaintext(self):
        vault = CredentialVault(self.root / "vault.json")
        key = "fixture-key-do-not-use"
        vault.set("openrouter", key)
        self.assertNotIn(key, vault.path.read_text())
        self.assertEqual(vault.get("openrouter"), key)
        vault.delete("openrouter")
        self.assertEqual(vault.get("openrouter"), "")


class ManagerTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows single instance")
    def test_second_instance_signals_existing_window(self):
        with tempfile.TemporaryDirectory() as identity:
            first, second = InstanceGuard(identity), InstanceGuard(identity)
            try:
                self.assertTrue(first.acquired)
                self.assertFalse(second.acquired)
                self.assertTrue(first.requested())
                self.assertFalse(first.requested())
            finally:
                second.close()
                first.close()

    def test_duplicate_jobs_and_cancelled_key_cannot_save(self):
        started, release = threading.Event(), threading.Event()
        vault = Mock()
        manager = ConnectionManager(vault, Mock())

        def check(*args):
            started.set()
            release.wait(2)
            return ProviderStats(authenticated=True)

        try:
            with patch("manager.check_api", check):
                self.assertTrue(manager.connect_key("openrouter", "fixture"))
                self.assertTrue(started.wait(1))
                self.assertFalse(manager.connect_key("openrouter", "second"))
                manager.cancel_login("openrouter")
                release.set()
                event = manager.events.get(timeout=2)
                self.assertEqual(event[1], "cancelled")
                vault.set.assert_not_called()
        finally:
            release.set()
            manager.shutdown()

    def test_cancelled_queued_browser_login_never_opens(self):
        started, release = threading.Event(), threading.Event()
        browsers = Mock()
        manager = ConnectionManager(Mock(), browsers)
        def blocked():
            started.set()
            release.wait(3)
            return ProviderStats()
        try:
            manager._submit("claude", "refresh", blocked, browser=True)
            self.assertTrue(started.wait(1))
            self.assertTrue(manager.connect_browser("chatgpt"))
            manager.cancel_login("chatgpt")
            release.set()
            events = [manager.events.get(timeout=3), manager.events.get(timeout=3)]
            self.assertIn(("chatgpt", "cancelled", None), events)
            browsers.open_login.assert_not_called()
        finally:
            release.set()
            manager.shutdown()

    def test_login_poll_is_passed_to_browser_without_refresh(self):
        browsers = Mock(check=Mock(return_value=ProviderStats()))
        manager = ConnectionManager(Mock(), browsers)
        try:
            self.assertTrue(manager.refresh("claude", login_poll=True))
            self.assertEqual(manager.events.get(timeout=2)[1], "poll")
            browsers.check.assert_called_once_with("claude", refresh=False, login_poll=True, manual=False)
        finally:
            manager.shutdown()

    def test_manual_verification_is_explicit(self):
        browsers = Mock(check=Mock(return_value=ProviderStats()))
        manager = ConnectionManager(Mock(), browsers)
        try:
            self.assertTrue(manager.refresh("claude", manual=True))
            manager.events.get(timeout=2)
            browsers.check.assert_called_once_with("claude", refresh=True, login_poll=False, manual=True)
        finally:
            manager.shutdown()

    def test_background_refresh_never_launches_a_closed_browser(self):
        with tempfile.TemporaryDirectory() as directory:
            browsers = BrowserSessions(Path(directory))
            with patch.object(browsers, "_open", side_effect=AssertionError("Background browser opened")):
                self.assertEqual(browsers.check("claude", refresh=True).status, "paused")
                self.assertEqual(browsers.check("chatgpt", login_poll=True).status, "closed")


class PkceTests(unittest.TestCase):
    def test_challenge_is_s256_base64url(self):
        verifier, challenge = pkce_pair()
        expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        self.assertEqual(challenge, expected)
        self.assertGreaterEqual(len(verifier), 43)
        self.assertNotIn("=", challenge)

    def test_cancellation_does_not_exchange_credentials(self):
        login = OpenRouterLogin(timeout=1, opener=lambda _: True)
        login.cancel()
        with patch("openrouter_auth.requests.post") as post:
            with self.assertRaises(AuthError):
                login.run()
            post.assert_not_called()

    def test_loopback_callback_and_exchange(self):
        callback_thread = None

        def opener(url):
            nonlocal callback_thread
            params = parse_qs(urlsplit(url).query)
            self.assertEqual(params["code_challenge_method"], ["S256"])
            # requests waits on unavailable IPv6 localhost before falling back on this host.
            # Address the IPv4 loopback server directly; the browser callback remains localhost.
            callback = params["callback_url"][0].replace("localhost", "127.0.0.1")

            def callback_request():
                bad = requests.get(callback.replace(login.path, "/wrong"), timeout=2)
                self.assertEqual(bad.status_code, 404)
                good = requests.get(callback + "?code=fixture-code", timeout=2)
                self.assertEqual(good.status_code, 200)
                self.assertEqual(good.headers["Cache-Control"], "no-store")

            callback_thread = threading.Thread(target=callback_request)
            callback_thread.start()
            return True

        login = OpenRouterLogin(timeout=3, opener=opener)
        with patch("openrouter_auth.requests.post", return_value=Mock(status_code=200, json=lambda: {"key": "fixture-key"})) as post:
            self.assertEqual(login.run(), "fixture-key")
            self.assertEqual(post.call_args.kwargs["json"]["code_verifier"], login.verifier)
            self.assertEqual(post.call_args.kwargs["json"]["code"], "fixture-code")
        callback_thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
