"""Exercise actual installed Chrome and profile persistence against a local fixture."""
from dataclasses import replace
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import faulthandler
import sys
import tempfile
import threading
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from browser_sessions import BrowserSessions
from providers import PROVIDERS


class Fixture(BaseHTTPRequestHandler):
    usage_status = 200
    usage_percent = 75
    gemini_percent = 0
    gemini_week = 6
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith('/api/auth/session'):
            body = json.dumps({} if 'guest=1' in self.path else {'user': {'id': 'fixture-user'}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if 'slow=1' in self.path:
                time.sleep(1)
            self.wfile.write(body)
            return
        if self.path.startswith("/api/organizations/fixture/usage"):
            body = json.dumps({"five_hour": {"utilization": 64, "resets_at": "2026-10-01T18:00:00Z"},
                               "seven_day": {"utilization": 95}}).encode()
            self.send_response(self.usage_status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if "slow=1" in self.path:
                time.sleep(2)
            self.wfile.write(body)
            return
        if self.path == '/usage':
            session_reset = (datetime.now().astimezone() + timedelta(hours=2)).strftime('%H:%M')
            weekly_reset = datetime.now().astimezone() + timedelta(days=5)
            months = ('Jan.', 'Feb.', 'Mär.', 'Apr.', 'Mai', 'Jun.', 'Jul.', 'Aug.', 'Sep.', 'Okt.', 'Nov.', 'Dez.')
            quota = (f'Nutzungslimits<br>PRO<br>Aktuelle Nutzung<br>{self.gemini_percent}&nbsp;% genutzt<br>'
                     f'Wird um {session_reset} zurückgesetzt<br>Wöchentliches Limit<br>'
                     f'Wird am {weekly_reset.day}. {months[weekly_reset.month-1]} um 09:56 zurückgesetzt<br>{self.gemini_week}&nbsp;% genutzt')
            content = ("<html><body><button class='account' hidden>Hidden account copy</button><button class='account'>Account</button>"
                       "<aside>Chat example: Aktuelle Nutzung 99% genutzt. Wöchentliches Limit 98% genutzt.</aside>"
                       "<usage-metrics-window>Loading</usage-metrics-window>"
                       f"<script>setTimeout(() => document.querySelector('usage-metrics-window').innerHTML = {json.dumps(quota)}, 1300);</script></body></html>")
        elif self.path == '/chatgpt-signed-in':
            content = ("<html><body><p>Log in</p><p>A chat can quote login labels.</p>"
                       "<script>fetch('/api/auth/session').then(r=>r.json()).then(() => "
                       "history.pushState({}, '', '/c/fixture'))</script></body></html>")
        elif self.path == '/chatgpt-cookie':
            content = "<html><body><button data-testid='accounts-profile-button'>Account</button><p>Sign in</p></body></html>"
        elif self.path == '/claude-home':
            content = "<html><body><button data-testid='user-menu-button'>Account</button></body></html>"
        elif self.path in ('/gemini-home', '/gemini-usage'):
            content = ("<html><body><button class='account' hidden>Hidden account copy</button><button class='account'>Account</button>"
                       "<p>Chat example: 5-hour usage 99% used. Weekly usage 98% used.</p>"
                       "<button onclick=\"document.getElementById('usage').hidden=false\">Settings</button>"
                       "<button id='usage' hidden onclick=\"document.getElementById('limits').hidden=false\">Usage limits</button>"
                       "<div id='limits' role='dialog' hidden><h2>5-hour usage</h2><p>20% used</p><p>Resets in 3 hours</p>"
                       "<h2>Weekly usage</h2><p>40% used</p><p>Resets in 4 days</p></div></body></html>")
        elif self.path == '/gemini-no-usage':
            content = "<html><body><button class='account'>Account</button><p>5-hour usage 99% used. Weekly usage 98% used.</p></body></html>"
        elif self.path == '/challenge':
            content = "<html><body><h1>Verify you are human</h1><input id='verification'></body></html>"
        elif self.path == "/structured":
            content = ("<html><body><button data-testid='user-menu-button'>Account</button>"
                       "<script>fetch('/api/organizations/fixture/usage')</script></body></html>")
        else:
            content = ("<html><body><button data-testid='user-menu-button'>Account</button>"
                       f"<h1>Current session</h1><p>{self.usage_percent}% used</p></body></html>") if self.path == "/settings/usage" else (
                       "<html><body><button>Log in</button><p>Public provider page</p></body></html>")
        body = content.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if self.path in ("/settings/usage", "/claude-home"):
            self.send_header("Set-Cookie", "sessionKey=fixture-not-a-real-login; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax")
        elif self.path == '/chatgpt-cookie':
            self.send_header('Set-Cookie', 'fixture-session.0=fixture-chunk-0; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax')
            self.send_header('Set-Cookie', 'fixture-session.1=fixture-chunk-1; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax')
        elif self.path.startswith('/gemini-') or self.path == '/usage':
            self.send_header('Set-Cookie', 'SID=fixture-google-login; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax')
        self.end_headers()
        self.wfile.write(body)


def run():
    faulthandler.dump_traceback_later(90, repeat=False)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    original = PROVIDERS["claude"]
    original_chatgpt = PROVIDERS['chatgpt']
    original_gemini = PROVIDERS['gemini_chat']
    fixture_base = f"http://127.0.0.1:{server.server_port}"
    with tempfile.TemporaryDirectory(prefix="tokentracker-browser-test-") as directory:
        sessions = BrowserSessions(Path(directory) / "profiles")
        try:
            PROVIDERS["claude"] = replace(original, url=fixture_base + "/settings/usage", login_url=fixture_base + "/login", domains=("127.0.0.1",))
            sessions.open_login('claude')
            first_page = sessions.sessions['claude'].page
            assert first_page.evaluate('navigator.webdriver') is False, 'Manual Chrome must not be flagged as webdriver'
            assert not sessions.sessions['claude'].headless
            public = sessions.check("claude", login_poll=True)
            assert public.status == "unauthorized", public
            print("Browser test: guest rejected", flush=True)
            first_page.goto(fixture_base + '/claude-home')
            result = sessions.check("claude", login_poll=True)
            assert result.authenticated, result
            assert result.progress == .25, result
            assert first_page.url.endswith('/claude-home'), 'Quota reader must not navigate the login/chat tab'
            assert first_page.evaluate('document.visibilityState') == 'visible', 'Quota reader must remain a background tab'
            assert sessions.sessions['claude'].usage_page is not None
            print("Browser test: normal Chrome, background DOM quota verified", flush=True)
            first_page = sessions.sessions["claude"].usage_page
            second = sessions.check("claude", refresh=True)
            assert sessions.sessions["claude"].page is first_page, "Refresh must reuse the existing browser"
            assert second.authenticated
            Fixture.usage_percent = 80
            assert sessions.check('claude', refresh=True).progress == .20, 'The app-owned quota tab must fetch fresh measurements'
            first_page.goto(fixture_base + '/structured')
            structured = sessions.check("claude", login_poll=True)
            assert structured.authenticated and structured.progress == .05, structured
            assert structured.status == "warning", "Weekly exhaustion must warn even with session capacity"
            assert [w.remaining_percent for w in structured.windows] == [36, 5]
            print("Browser test: structured quota verified", flush=True)
            started = time.monotonic()
            first_page.evaluate("() => { fetch('/api/organizations/fixture/usage?slow=1'); return true; }")
            sessions.check("claude", login_poll=True)
            assert time.monotonic() - started < 1.5, "A slow response body must not block the login worker"
            first_page.wait_for_timeout(2200)
            Fixture.usage_status = 401
            first_page.evaluate("() => fetch('/api/organizations/fixture/usage').then(r => r.text())")
            unauthorized = sessions._check_page("claude", sessions.sessions['claude'], first_page, True)
            assert unauthorized.status == "unauthorized", "Rejected authentication overrides leftover cookies/avatar"
            print("Browser test: expired auth rejected", flush=True)
            Fixture.usage_status = 200
            sessions.close("claude")
            open_native = sessions._open
            minimized = []
            def record_reader(*args, **kwargs):
                reader = open_native(*args, **kwargs)
                cdp = reader.context.new_cdp_session(reader.page)
                try:
                    minimized.append(cdp.send('Browser.getWindowForTarget')['bounds']['windowState'])
                finally:
                    cdp.detach()
                assert reader.page.evaluate('navigator.webdriver') is False
                assert reader.background and not reader.headless
                return reader
            with patch.object(sessions, '_open', side_effect=record_reader):
                closed_profile = sessions.check('claude', refresh=True)
            assert closed_profile.authenticated and closed_profile.progress == .20, closed_profile
            assert minimized == ['minimized'], minimized
            assert 'claude' not in sessions.sessions, 'A temporary minimized reader must close after the measurement'
            print('Browser test: stored login read with normal minimized Chrome; reader closed', flush=True)
            session = sessions._open("claude")
            assert any(c["name"] == "sessionKey" for c in session.context.cookies()), "Profile must persist login cookies"
            sessions.open_login("claude")
            assert not sessions.sessions["claude"].headless, "Login must be visible"
            print("Browser test: visible login opened", flush=True)
            page = sessions.sessions["claude"].page
            page.goto(fixture_base + "/login")
            session = sessions.sessions["claude"]
            with_counter = []
            page.on("framenavigated", lambda frame: with_counter.append(frame.url))
            for _ in range(5):
                sessions.check("claude", login_poll=True)
            assert page.url.endswith("/login") and not with_counter, "Login polls must never reload or navigate"
            sessions.open_login('claude')
            assert page.url.endswith('/login') and not with_counter, 'Reopening must preserve a live login form'
            page.goto(fixture_base.replace("127.0.0.1", "localhost") + "/login")
            redirect_url = page.url
            with_counter.clear()
            sessions.check("claude", login_poll=True)
            assert page.url == redirect_url and not with_counter, "Foreign authentication redirects must remain untouched"
            page.goto(fixture_base + '/challenge')
            page.locator('#verification').fill('fixture-in-progress')
            with_counter.clear()
            for _ in range(3):
                assert sessions.check('claude', login_poll=True).status == 'warning'
            assert not with_counter and page.locator('#verification').input_value() == 'fixture-in-progress', 'Security checks must retain their form and typed input'
            print("Browser test: login and redirects untouched", flush=True)

            PROVIDERS['gemini_chat'] = replace(original_gemini, url=fixture_base + '/gemini-usage', login_url=fixture_base + '/gemini-home',
                                               domains=('127.0.0.1',), session_cookies=('SID',), account_selectors=('.account',))
            sessions.open_login('gemini_chat')
            gemini_page = sessions.sessions['gemini_chat'].page
            gemini_quota = sessions.check('gemini_chat', login_poll=True)
            assert [w.remaining_percent for w in gemini_quota.windows] == [80, 60], gemini_quota
            assert all(w.resets_at for w in gemini_quota.windows)
            assert gemini_page.url.endswith('/gemini-home'), 'Usage UI must not replace the user tab'
            assert gemini_page.locator('#usage').is_hidden(), 'Settings must only open on the reader tab'
            sessions.sessions['gemini_chat'].usage_page.goto(fixture_base + '/gemini-no-usage')
            no_quota = sessions.check('gemini_chat', login_poll=True)
            assert no_quota.authenticated and all(w.remaining_percent is None for w in no_quota.windows), 'Chat percentages are never subscription data'
            sessions.close('gemini_chat')
            print('Browser test: Gemini dialog has two independent windows; chat content ignored', flush=True)

            PROVIDERS['gemini_chat'] = replace(PROVIDERS['gemini_chat'], url=fixture_base + '/usage')
            sessions.open_login('gemini_chat')
            original_google_tab = sessions.sessions['gemini_chat'].page
            modern = sessions.check('gemini_chat', login_poll=True)
            assert [w.remaining_percent for w in modern.windows] == [100, 94], modern
            assert all(w.resets_at for w in modern.windows), 'Both real-style German reset texts must be parsed'
            assert original_google_tab.url.endswith('/gemini-home'), 'The reader must preserve the user tab'
            Fixture.gemini_percent, Fixture.gemini_week = 25, 45
            modern_refresh = sessions.check('gemini_chat', refresh=True)
            assert [w.remaining_percent for w in modern_refresh.windows] == [75, 55], modern_refresh
            sessions.close('gemini_chat')
            modern_closed = sessions.check('gemini_chat', refresh=True)
            assert [w.remaining_percent for w in modern_closed.windows] == [75, 55], modern_closed
            assert 'gemini_chat' not in sessions.sessions, 'The owned minimized Gemini reader must close'
            print('Browser test: real-style Gemini page, hidden account copy, delayed data, German resets, fresh/closed browser reads verified', flush=True)

            PROVIDERS['chatgpt'] = replace(original_chatgpt, url=fixture_base + '/login', domains=('127.0.0.1',), session_cookies=('fixture-session',))
            sessions.open_login('chatgpt')
            chat_session = sessions.sessions['chatgpt']
            login_page = chat_session.page
            product = chat_session.context.new_page()
            product.goto(fixture_base + '/chatgpt-signed-in')
            assert sessions.check('chatgpt', login_poll=True).authenticated, 'Login completed in a different tab must be recognized'
            assert sessions.sessions['chatgpt'].page is product
            assert product.url.endswith('/c/fixture'), 'Fixture must execute its SPA redirect'
            assert sessions.check('chatgpt', login_poll=True).authenticated, 'SPA navigation must preserve verified identity'
            assert not sessions._check_page('chatgpt', chat_session, login_page, True).authenticated, 'An authenticated tab must not authenticate the old guest tab'
            print('Browser test: ChatGPT new-tab login and SPA navigation recognized', flush=True)
            product.evaluate("() => { fetch('/api/auth/session?guest=1&slow=1'); setTimeout(() => fetch('/api/auth/session'), 30); }")
            product.wait_for_timeout(1400)
            assert sessions.check('chatgpt', login_poll=True).authenticated, 'A slow older guest response must not overwrite newer successful authentication'
            product.goto(fixture_base + '/login')
            assert not sessions.check('chatgpt', login_poll=True).authenticated, 'A new guest document must invalidate old login evidence'
            product.goto(fixture_base + '/chatgpt-cookie')
            assert sessions.check('chatgpt', login_poll=True).authenticated, 'A stored chunked session cookie plus account control must be recognized'
            chat_session.browser.close()  # Disconnect this reader, leaving native Chrome open.
            sessions.sessions.pop('chatgpt')
            with patch('browser_sessions.subprocess.Popen', side_effect=AssertionError('Reattach launched Chrome')):
                assert sessions.check('chatgpt').authenticated, 'App restart must reattach to a live saved profile'
            chat_session = sessions.sessions['chatgpt']
            product = chat_session.page
            assert product.url.endswith('/chatgpt-cookie'), 'Reattach must preserve the current document'
            login_page = next(p for p in chat_session.context.pages if p.url.endswith('/login'))
            product.close()
            chat_session.page = login_page
            chat_session.context.clear_cookies()
            assert not sessions.check('chatgpt', login_poll=True).authenticated, 'Closed product tabs must not leave a false login in the guest tab'
            sessions.close('chatgpt')

            sessions._request_close(sessions.profile_root / "claude")
            session.browser.close()
            # Let Playwright receive browser-disconnected notification.
            try:
                page.wait_for_timeout(200)
            except Exception:
                pass
            with patch.object(sessions, "_open", side_effect=AssertionError("Closed login reopened")):
                closed = sessions.check("claude", login_poll=True)
                assert closed.status == "closed", closed
                assert sessions.check("chatgpt", login_poll=True).status == "closed"
            sessions.forget("claude")
            assert not (sessions.profile_root / "claude").exists(), "Disconnect must remove only this profile"
            with patch.object(sessions, '_open', side_effect=AssertionError('Background browser opened')):
                assert sessions.check('chatgpt', refresh=True).status == 'paused'
            print("Browser smoke: passed (normal Chrome, background quotas, multi-tab login, SPA navigation, response races, stored session, guest/expired/closed rejection, unchanged redirects, persistence, disconnect)")
        finally:
            sessions.shutdown()
            PROVIDERS["claude"] = original
            PROVIDERS['chatgpt'] = original_chatgpt
            PROVIDERS['gemini_chat'] = original_gemini
            server.shutdown()
            server.server_close()
            faulthandler.cancel_dump_traceback_later()


if __name__ == "__main__":
    run()
