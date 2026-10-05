"""Separate Chrome profiles, one Playwright owner thread, conservative login checks."""
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
from urllib.parse import urlsplit

import requests

from api_clients import ProviderStats
from providers import PROVIDERS
from storage import DATA_DIR
from observed_usage import observation, relevant_response, claude_usage
from subscription_usage import empty_quota, page_usage


class BrowserError(RuntimeError):
    pass


def browser_executable():
    candidates = [
        Path(os.environ.get("PROGRAMFILES", "C:/Program Files")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("PROGRAMFILES(X86)", "C:/Program Files (x86)")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("PROGRAMFILES(X86)", "C:/Program Files (x86)")) / "Microsoft/Edge/Application/msedge.exe",
        Path(os.environ.get("PROGRAMFILES", "C:/Program Files")) / "Microsoft/Edge/Application/msedge.exe",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    for name in ("google-chrome", "chromium", "chromium-browser", "msedge"):
        if path := shutil.which(name):
            return path
    raise BrowserError("Chrome oder Microsoft Edge wurde nicht gefunden. Bitte einen dieser Browser installieren.")


def host_allowed(url, domains):
    host = (urlsplit(url).hostname or "").lower()
    return any(host == domain or host.endswith("." + domain) for domain in domains)


def authenticated_evidence(provider, url, cookies, account_visible, logout_visible=False, local_token=False):
    """A page title/provider name, a Google cookie, or a guest composer is not a login."""
    if not host_allowed(url, provider.domains):
        return False
    # Authentication cookies may belong to a parent domain, but the page must be the actual product.
    if not host_allowed(url, ((urlsplit(provider.url).hostname or "").removeprefix("www."),)):
        return False
    if re.search(r"/(?:login|signin|sign-in|auth)(?:/|$)", urlsplit(url).path, re.I):
        return False
    now = time.time()
    cookie_names = set()
    for cookie in cookies:
        domain = str(cookie.get("domain", "")).lstrip(".")
        expires = cookie.get("expires", -1)
        if (any(domain == allowed or domain.endswith("." + allowed) for allowed in provider.domains)
                and (expires == -1 or expires > now) and cookie.get("value")):
            cookie_names.add(str(cookie.get("name", "")))
    has_session = any(name in cookie_names or any(n.startswith(name + ".") for n in cookie_names)
                      for name in provider.session_cookies)
    # A visible authenticated account control and a session credential are both required.
    # Explicit logout is also strong authenticated UI evidence for providers using different cookies.
    return bool((account_visible and (has_session or local_token)) or logout_visible)


def extract_usage(text, provider_id):
    stats = ProviderStats(label="Kein Restzähler verfügbar", detail="Angemeldet. Es ist kein automatisch lesbares Restlimit vorhanden.",
                          metrics=[("Nutzungslimit", "Nicht verfügbar"), ("Verbindung", "Browser-Sitzung")], authenticated=True)
    reached = re.search(r"(?:you(?:'ve| have) reached (?:your|the)|you (?:have |)hit (?:your|the)|"
                        r"du hast (?:dein|das)|usage limit reached|message limit reached|"
                        r"limit (?:ist )?erreicht|zu viele anfragen|too many requests)", text, re.I)
    if reached:
        stats.status, stats.value, stats.label = "warning", "Limit erreicht", "Nutzungsstatus"
        stats.detail = "Der Anbieter zeigt eine aktive Limit-Meldung. Bitte später erneut versuchen."
    remaining = re.search(r"(\d+)\s+(?:messages?|Nachrichten)\s+(?:left|remaining|übrig|verbleibend)", text, re.I)
    if remaining:
        stats.value, stats.label = remaining.group(1), "Nachrichten verfügbar"
        stats.detail = "Aus der aktuell angezeigten Limit-Meldung des Anbieters."
    if provider_id == "claude":
        if measured := page_usage(text, provider_id):
            return measured
        return empty_quota('Claude-Abo', 'Die Anmeldung ist bestätigt. Die 5-Stunden-/Wochenwerte werden aus der Nutzungsübersicht geladen.', authenticated=True)
    if provider_id == 'gemini_chat':
        if measured := page_usage(text, provider_id):
            return measured
        return empty_quota('Gemini-Abo', 'Die Anmeldung ist bestätigt. Die Abo-Limits stehen in Gemini unter Einstellungen → Nutzungslimits.', authenticated=True)
    reset = re.search(r"(?:resets? (?:at|in)|zurückgesetzt (?:um|in)|reset (?:um|in))\s*([^\n]{1,55})", text, re.I)
    if reset:
        stats.metrics = [("Reset", reset.group(1).strip()), *stats.metrics[:1]]
    return stats


@dataclass
class PageEvidence:
    generation: int = 0
    sequence: int = 0
    authenticated: bool | None = None
    observed_at: float = 0
    usage: object = None


@dataclass
class Session:
    browser: object
    context: object
    page: object
    headless: bool
    process: object = None
    evidence: dict = field(default_factory=dict)
    requests: dict = field(default_factory=dict)
    sequence: int = 0
    usage_page: object = None


class BrowserSessions:
    """All methods must run on the same worker thread. Never drive Chrome from the UI."""
    def __init__(self, profile_root=DATA_DIR / "browser"):
        self.profile_root = Path(profile_root)
        self.sessions = {}
        self.playwright = None
        self.last_error = None

    def _engine(self):
        if self.playwright is None:
            from playwright.sync_api import sync_playwright
            self.playwright = sync_playwright().start()
        return self.playwright

    def _endpoint(self, profile):
        try:
            lines = (profile / "DevToolsActivePort").read_text().splitlines()
            port = int(lines[0])
            if not 1 <= port <= 65535 or not lines[1].startswith("/devtools/browser/"):
                return None
            endpoint = f"http://127.0.0.1:{port}"
            response = requests.get(endpoint + "/json/version", timeout=1, proxies={"http": "", "https": ""})
            target = urlsplit(response.json().get("webSocketDebuggerUrl", ""))
            if (response.status_code == 200 and target.scheme == "ws" and target.hostname == "127.0.0.1"
                    and target.port == port and target.path == lines[1]):
                return endpoint
        except (OSError, ValueError, IndexError, requests.RequestException):
            pass
        return None

    def _open(self, provider_id, allow_launch=True):
        existing = self.sessions.get(provider_id)
        if existing and existing.browser.is_connected():
            if existing.headless:
                self.close(provider_id)
            else:
                return existing
        profile = (self.profile_root / provider_id).resolve()
        profile.mkdir(parents=True, exist_ok=True)
        endpoint = self._endpoint(profile)
        process = None
        if not endpoint:
            if not allow_launch:
                raise BrowserError("Das Anbieter-Fenster wurde geschlossen. Bitte über »Anmelden« erneut öffnen.")
            # Port 0 and headless both enable navigator.webdriver in Chrome. A manual
            # sign-in must use a normal installed browser, without automation flags
            # or scripts that alter its fingerprint. CDP remains loopback-only.
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            args = [browser_executable(), f"--user-data-dir={profile}", f"--remote-debugging-port={port}",
                    "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check",
                    "--window-size=1180,860", "--new-window"]
            args.append("about:blank")
            process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try:
                    response = requests.get(f"http://127.0.0.1:{port}/json/version", timeout=1,
                                            proxies={"http": "", "https": ""})
                    target = urlsplit(response.json().get("webSocketDebuggerUrl", ""))
                    if (response.status_code == 200 and target.scheme == "ws" and target.hostname == "127.0.0.1"
                            and target.port == port and re.fullmatch(r"/devtools/browser/[\w-]+", target.path)):
                        # Fixed-port Chrome does not write DevToolsActivePort itself.
                        (profile / "DevToolsActivePort").write_text(f"{port}\n{target.path}\n")
                        endpoint = f"http://127.0.0.1:{port}"
                except (requests.RequestException, ValueError):
                    pass
                if endpoint:
                    break
                if process.poll() is not None:
                    raise BrowserError("Das Anbieter-Browserprofil ist bereits geöffnet oder gesperrt. Das zugehörige Fenster schließen und erneut versuchen.")
                time.sleep(0.25)
            if not endpoint:
                # This is the process we just created, never a user's unrelated Chrome process.
                if process.poll() is None:
                    process.terminate()
                raise BrowserError("Der Browser ist nicht bereit. Bitte die Anmeldung erneut starten.")
        try:
            browser = self._engine().chromium.connect_over_cdp(endpoint, timeout=15000)
            context = browser.contexts[0]
            provider = PROVIDERS[provider_id]
            page = next((p for p in context.pages if host_allowed(p.url, provider.domains)), None)
            page = page or next((p for p in context.pages if p.url == "about:blank"), None) or context.new_page()
            page.set_default_timeout(3000)
            version = browser.new_browser_cdp_session().send("Browser.getVersion")
            headless = "HeadlessChrome" in version.get("userAgent", "")
            session = Session(browser, context, page, headless, process)
            self.sessions[provider_id] = session
            def watch_page(owner):
                owner.set_default_timeout(3000)
                owner.on("close", lambda: session.evidence.pop(owner, None))
            for owner in context.pages:
                watch_page(owner)
            context.on("page", watch_page)
            def started(request):
                try:
                    frame = request.frame
                    owner = frame.page
                    if frame != owner.main_frame:
                        return
                    evidence = session.evidence.setdefault(owner, PageEvidence())
                    if request.is_navigation_request():
                        # A real document request invalidates old evidence. SPA
                        # pushState/fragments do not: those retain the same login.
                        evidence.generation += 1
                        evidence.authenticated, evidence.observed_at, evidence.usage = None, 0, None
                    elif relevant_response(provider_id, request.url):
                        session.sequence += 1
                        session.requests[request] = (owner, evidence.generation, session.sequence)
                except Exception:
                    pass
            def capture(request):
                source = session.requests.pop(request, None)
                if source is None:
                    return
                try:
                    owner, generation, sequence = source
                    evidence = session.evidence[owner]
                    if evidence.generation != generation or sequence < evidence.sequence or owner.is_closed():
                        return
                    response = request.response()
                    if response is None:
                        return
                    payload = response.json() if response.status == 200 else None
                    result = observation(provider_id, response.url, response.status, payload)
                    if result is not None:
                        evidence.authenticated, usage = result
                        evidence.sequence, evidence.observed_at = sequence, time.monotonic()
                        if not evidence.authenticated:
                            evidence.usage = None
                        elif usage is not None:
                            evidence.usage = usage
                except Exception:
                    pass
            # A response event only guarantees headers. Reading JSON inside it can
            # block the sole browser worker on a slow body, including during login.
            # requestfinished guarantees the body's download has already completed.
            context.on("request", started)
            context.on("requestfinished", capture)
            context.on("requestfailed", lambda request: session.requests.pop(request, None))
            if headless or page.evaluate("navigator.webdriver"):
                if not allow_launch:
                    self.sessions.pop(provider_id, None)
                    browser.close()
                    raise BrowserError("Das ältere Anbieter-Fenster schließen und über »Anmelden« neu öffnen.")
                self.close(provider_id)
                if process is not None:
                    raise BrowserError("Der Browser wurde im Automationsmodus gestartet. Bitte Chrome oder Edge aktualisieren und erneut anmelden.")
                return self._open(provider_id)
            return session
        except BrowserError:
            raise
        except Exception:
            raise BrowserError("Die Browser-Verbindung konnte nicht hergestellt werden. Anmeldung erneut versuchen.") from None

    def open_login(self, provider_id):
        existing = self.sessions.get(provider_id)
        session = self._open(provider_id)
        if session.page.is_closed():
            session.page = session.context.new_page()
        # Reopening a live login never replaces its redirects, verification form,
        # or an already signed-in chat. Closed profiles are reused on the next start.
        if existing is not session or session.page.url == "about:blank":
            provider = PROVIDERS[provider_id]
            session.page.goto(provider.login_url or provider.url, wait_until="commit", timeout=15000)
        session.page.bring_to_front()
        return ProviderStats("pending", "Anmeldung offen", detail="Im Browser anmelden. Die Verbindung wird automatisch geprüft.")

    def check(self, provider_id, refresh=False, login_poll=False, manual=False):
        provider = PROVIDERS[provider_id]
        try:
            session = self.sessions.get(provider_id)
            if (not login_poll and not session and self._endpoint(self.profile_root / provider_id)):
                # Reattach after an app restart only if this exact profile is still
                # open. This path cannot start a browser or change its document.
                session = self._open(provider_id, allow_launch=False)
            live = (session and session.browser.is_connected() and session.context.pages
                    and self._endpoint(self.profile_root / provider_id))
            if not live:
                if login_poll:
                    return ProviderStats("closed", "Login-Fenster geschlossen", detail="Die Anmeldung wurde beendet. Über »Anmelden« erneut öffnen.")
                if not manual:
                    return ProviderStats("paused", "Browser geschlossen", "Abruf pausiert", detail="Die Anmeldung bleibt gespeichert. »Prüfen« öffnet das Anbieter-Fenster und lädt die Abo-Limits.")
                else:
                    self.open_login(provider_id)
                    session = self.sessions[provider_id]
            # OAuth can leave its original login tab open and complete in another
            # tab. Inspect every product tab, keeping their evidence separate.
            pages = [p for p in reversed(session.context.pages) if not p.is_closed()
                     and host_allowed(p.url, ((urlsplit(provider.url).hostname or "").removeprefix("www."),))]
            if not pages:
                return ProviderStats("pending", "Anmeldung läuft", detail="Die Anmeldung im Anbieter-Browser abschließen.")
            results = []
            for page in pages[:8]:
                result = self._check_page(provider_id, session, page, login_poll)
                if result.authenticated:
                    session.page = page
                    if provider_id == "claude":
                        return self._read_claude_usage(session, page, result, refresh)
                    if provider_id == 'gemini_chat':
                        return self._read_gemini_usage(session, page, result, refresh)
                    return result
                results.append(result)
            return max(results, key=lambda r: {"warning": 4, "unverified": 3, "pending": 2,
                                               "unauthorized": 1, "error": 0}.get(r.status, 0))
        except BrowserError as error:
            return ProviderStats("error", "Browser nicht bereit", detail=str(error))
        except Exception:
            return ProviderStats("error", "Browser-Abruf fehlgeschlagen", detail="Das Anbieter-Fenster öffnen und die Verbindung erneut prüfen.")

    def _check_page(self, provider_id, session, page, login_poll):
        provider = PROVIDERS[provider_id]
        try:
            page.locator("body").wait_for(state="visible", timeout=2000)
            # SPA hydration may follow DOMContentLoaded; allow bounded settling.
            page.wait_for_timeout(300 if login_poll else 900)
            text = ""
            # Google keeps hidden desktop/mobile copies of its account link.
            # The first match can be hidden while another is the live account.
            account = any(page.locator(selector).nth(i).is_visible()
                          for selector in provider.account_selectors
                          for i in range(min(page.locator(selector).count(), 10)))
            if provider_id == "claude" and urlsplit(page.url).path.rstrip("/") == "/settings/usage":
                text = page.locator("body").inner_text(timeout=5000)[:60000]
                account = account or bool(re.search(r"(?:Current session|Aktuelle Sitzung|All models|Alle Modelle)", text, re.I))
            logout_name = re.compile(r"^(?:Log out|Sign out|Logout|Abmelden)$", re.I)
            logout_visible = False
            for role in ("button", "link", "menuitem"):
                controls = page.get_by_role(role, name=logout_name, exact=True)
                if any(controls.nth(i).is_visible() for i in range(min(controls.count(), 5))):
                    logout_visible = True
                    break
            local_token = False
            if provider_id == "deepseek":
                local_token = page.evaluate("""() => ['userToken','token','ds_token'].some(k => {
                    const v = localStorage.getItem(k); return !!v && v !== 'null' && v !== 'undefined';
                })""")
                # DeepSeek exposes its account action in a sidebar rather than a named avatar.
                account = account or page.get_by_text(re.compile(r"^(?:My Profile|Mein Profil|Personal info|个人信息)$", re.I)).first.is_visible()
            cookies = session.context.cookies()
            evidence = session.evidence.get(page, PageEvidence())
            fresh_observation = evidence.observed_at > 0 and time.monotonic() - evidence.observed_at < 300
            observed = evidence.authenticated and fresh_observation
            product_page = host_allowed(page.url, ((urlsplit(provider.url).hostname or "").removeprefix("www."),))
            if fresh_observation and evidence.authenticated is False:
                challenge_text = page.title() + '\n' + page.locator('body').inner_text(timeout=3000)[:15000]
                if re.search(r'verify.*human|verifying.*human|checking your browser|just a moment|bestätigen.*mensch', challenge_text, re.I):
                    return empty_quota(provider.name, 'Bitte die Anbieter-Sicherheitsprüfung über »Anbieter-Fenster öffnen« abschließen. Die Anmeldung bleibt gespeichert.', 'warning')
                return ProviderStats("unauthorized", "Nicht angemeldet", detail="Bitte im Anbieter-Browser anmelden und anschließend erneut prüfen.")
            if ((observed and product_page and not re.search(r"/(login|signin|auth)(/|$)", urlsplit(page.url).path))
                    or authenticated_evidence(provider, page.url, cookies, account, logout_visible, local_token)):
                if observed and evidence.usage is not None:
                    return evidence.usage
                # Chat transcripts can contain words such as "limit reached". Read actual notices only.
                if provider_id == "claude" and urlsplit(page.url).path.rstrip("/") == "/settings/usage":
                    usage_text = text
                else:
                    notices = page.locator('[role="alert"], [data-testid*="limit-notice"], [data-testid*="rate-limit"]')
                    usage_text = "\n".join(notices.nth(i).inner_text() for i in range(min(notices.count(), 10))
                                          if notices.nth(i).is_visible())
                return extract_usage(usage_text, provider_id)
            # Inspect challenge text only when account evidence is absent. An
            # authenticated chat can discuss bot checks without being blocked.
            text = text or page.locator("body").inner_text(timeout=5000)[:20000]
            if re.search(r"verify you are human|verifying you are human|checking your browser|"
                         r"bestätigen.*mensch|just a moment|unusual traffic|ungewöhnlichen datenverkehr", text + '\n' + page.title(), re.I):
                return ProviderStats("warning", "Browser-Prüfung", detail="Bitte die Sicherheitsprüfung im Anbieter-Browser abschließen. Die App wartet und lädt den Login nicht neu.")
            login_name = re.compile(r"^(?:Log in|Sign in|Anmelden|Continue with Google|Mit Google fortfahren)$", re.I)
            if any(page.get_by_role(role, name=login_name, exact=True).first.is_visible() for role in ("button", "link")):
                return ProviderStats("unauthorized", "Nicht angemeldet", detail="Bitte im Anbieter-Browser anmelden und anschließend erneut prüfen.")
            return ProviderStats("unverified", "Anmeldung nicht bestätigt", detail="Bitte im Browser das Konto-Menü öffnen und dann »Prüfen« wählen.")
        except Exception:
            return ProviderStats("error", "Browser-Abruf fehlgeschlagen", detail="Das Anbieter-Fenster öffnen und die Verbindung erneut prüfen.")

    def _read_claude_usage(self, session, account_page, confirmed, refresh):
        """Load the original usage page in a background tab only after verified login."""
        try:
            if urlsplit(account_page.url).path.rstrip("/") == "/settings/usage":
                if refresh and account_page is session.usage_page:
                    account_page.reload(wait_until="domcontentloaded", timeout=15000)
                    confirmed = self._check_page("claude", session, account_page, False)
                return self._wait_claude_quota(session, account_page, confirmed)
            if confirmed.progress is not None and not refresh:
                return confirmed
            page = session.usage_page
            if page is None or page.is_closed():
                cdp = session.browser.new_browser_cdp_session()
                try:
                    with session.context.expect_page(timeout=5000) as created:
                        cdp.send("Target.createTarget", {"url": "about:blank", "background": True})
                    page = session.usage_page = created.value
                finally:
                    cdp.detach()
                page.set_default_timeout(3000)
                page.goto(PROVIDERS["claude"].url, wait_until="domcontentloaded", timeout=15000)
            elif refresh:
                # Only the tab created by this reader is refreshed, never a user's chat.
                # Claude rewrites the usage-dialog URL to /new; reloading /new
                # would open a chat instead of fetching fresh subscription data.
                page.goto(PROVIDERS['claude'].url, wait_until="domcontentloaded", timeout=15000)
            # Claude may route /settings/usage into a settings dialog on /new.
            # Its original structured usage response remains the trusted source.
            result = self._wait_claude_quota(session, page, empty_quota('Claude-Abo', authenticated=confirmed.authenticated))
            if not any(w.used_percent is not None for w in result.windows):
                result = self._check_page("claude", session, page, False)
            if result.authenticated:
                return self._wait_claude_quota(session, page, result)
            confirmed.detail = "Angemeldet. Nutzungsübersicht noch nicht lesbar; die Prüfung gegebenenfalls im Claude-Tab abschließen."
        except Exception as error:
            self.last_error = 'claude-usage:' + type(error).__name__
            confirmed.detail = "Angemeldet. Die Claude-Nutzungsübersicht ist derzeit nicht lesbar."
        return confirmed

    def _wait_claude_quota(self, session, page, confirmed):
        """Hydration can authenticate before the usage request has completed."""
        if any(w.used_percent is not None for w in confirmed.windows):
            return confirmed
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and not page.is_closed():
            page.wait_for_timeout(250)  # Pump completed responses on the owner thread.
            evidence = session.evidence.get(page)
            if evidence and evidence.observed_at > 0:
                if evidence.authenticated is False:
                    return self._check_page('claude', session, page, False)
                if evidence.usage is not None:
                    return evidence.usage
            if confirmed.authenticated and urlsplit(page.url).path.rstrip('/') == '/settings/usage':
                try:
                    text = page.locator('body').inner_text(timeout=1000)[:60000]
                    if result := page_usage(text, 'claude'):
                        return result
                except Exception:
                    # React may replace/redirect the document while opening the
                    # settings dialog. Continue receiving its usage response.
                    pass
        confirmed.detail = 'Claude hat noch keine lesbaren Abo-Messwerte geliefert. Bitte später aktualisieren.'
        return confirmed

    def _read_gemini_usage(self, session, account_page, confirmed, refresh):
        try:
            page = session.usage_page
            if page is None or page.is_closed():
                cdp = session.browser.new_browser_cdp_session()
                try:
                    with session.context.expect_page(timeout=5000) as created:
                        cdp.send('Target.createTarget', {'url': 'about:blank', 'background': True})
                    page = created.value
                finally:
                    cdp.detach()
                page.goto(PROVIDERS['gemini_chat'].url, wait_until='domcontentloaded', timeout=15000)
                session.usage_page = page
                page.set_default_timeout(3000)
            elif refresh:
                page.goto(PROVIDERS['gemini_chat'].url, wait_until='domcontentloaded', timeout=15000)
            if re.fullmatch(r'/(?:u/\d+/)?usage/?', urlsplit(page.url).path):
                return self._wait_gemini_quota(page, confirmed, dedicated=True)
            usage_name = re.compile(r'^(?:Usage limits|Usage|Nutzungslimits|Nutzung|Nutzungsbeschränkungen)$', re.I)
            def visible_control(name):
                for role in ('button', 'menuitem', 'link'):
                    controls = page.get_by_role(role, name=name, exact=True)
                    for i in range(min(controls.count(), 8)):
                        if controls.nth(i).is_visible():
                            return controls.nth(i)
                return None
            control = visible_control(usage_name)
            if control is None:
                settings = visible_control(re.compile(r'^(?:Settings|Settings (?:&|and) help|Einstellungen|Einstellungen (?:&|und) Hilfe)$', re.I))
                if settings is not None:
                    settings.click(timeout=3000)
                    page.wait_for_timeout(300)
                    control = visible_control(usage_name)
            if control is not None:
                control.click(timeout=3000)
            else:
                confirmed.detail = 'Gemini ist angemeldet. Einstellungen → Nutzungslimits ist derzeit nicht lesbar.'
                return confirmed
            return self._wait_gemini_quota(page, confirmed, dedicated=False)
        except Exception:
            confirmed.detail = 'Geminis Abo-Nutzungsübersicht ist derzeit nicht lesbar. »Anbieter-Fenster öffnen« und die Anmeldung prüfen.'
        return confirmed

    def _wait_gemini_quota(self, page, confirmed, dedicated):
        """Read only an owned usage page or the panel opened via its usage action."""
        deadline = time.monotonic() + 10
        partial = None
        while time.monotonic() < deadline and not page.is_closed():
            page.wait_for_timeout(250)
            try:
                expected_host = urlsplit(PROVIDERS['gemini_chat'].url).hostname
                if urlsplit(page.url).hostname != expected_host:
                    break
                on_usage_page = bool(re.fullmatch(r'/(?:u/\d+/)?usage/?', urlsplit(page.url).path))
                if dedicated and not on_usage_page:
                    break  # Redirects/sign-in pages are not quota documents.
                if on_usage_page:
                    components = page.locator('usage-metrics-window')
                    texts = [components.nth(i).inner_text(timeout=1000)[:12000]
                             for i in range(min(components.count(), 5)) if components.nth(i).is_visible()]
                else:
                    dialogs = page.get_by_role('dialog')
                    texts = [dialogs.nth(i).inner_text(timeout=1000)[:12000]
                             for i in range(min(dialogs.count(), 8)) if dialogs.nth(i).is_visible()]
                # Never fall back to body/chat text. Unknown schemas stay unknown.
                for text in texts:
                    if result := page_usage(text, 'gemini_chat'):
                        partial = result
                        if all(window.used_percent is not None for window in result.windows):
                            return result
            except Exception:
                pass  # The SPA may be replacing its loading view.
        if partial:
            partial.detail = 'Gemini meldet derzeit nur eines der beiden Abo-Zeitfenster. Nicht gemeldete Werte bleiben unbekannt.'
            return partial
        confirmed.detail = 'Gemini ist angemeldet, hat aber noch keine lesbaren Abo-Messwerte geliefert. Bitte später aktualisieren.'
        return confirmed

    def _request_close(self, profile):
        """Send Chrome its close command without awaiting an acknowledgement from a dying process."""
        endpoint = self._endpoint(profile)
        if not endpoint:
            return
        import websocket
        expected_path = (profile / "DevToolsActivePort").read_text().splitlines()[1]
        response = requests.get(endpoint + "/json/version", timeout=1, proxies={"http": "", "https": ""})
        target = response.json().get("webSocketDebuggerUrl", "")
        parsed = urlsplit(target)
        if (parsed.scheme != "ws" or parsed.hostname != "127.0.0.1" or
                parsed.port != urlsplit(endpoint).port or parsed.path != expected_path):
            raise BrowserError("Das Anbieter-Profil konnte nicht eindeutig zugeordnet werden.")
        connection = websocket.create_connection(target, timeout=1.5, suppress_origin=True,
                                                 http_no_proxy=["127.0.0.1", "localhost"])
        try:
            connection.send(json.dumps({"id": 1, "method": "Browser.close", "params": {}}))
        finally:
            connection.close(timeout=.2)

    def close(self, provider_id):
        session = self.sessions.pop(provider_id, None)
        if not session:
            return
        try:
            if session.browser.is_connected():
                self._request_close(self.profile_root / provider_id)
        except Exception:
            pass
        # Browser.close() disconnects this CDP client; it does not wait for Chrome
        # to acknowledge Browser.close on a newly attached child CDP session.
        try:
            session.browser.close()
        except Exception:
            pass
        if session.process:
            try:
                session.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                session.process.terminate()
                session.process.wait(timeout=5)
        else:
            deadline = time.monotonic() + 5
            profile = self.profile_root / provider_id
            while self._endpoint(profile) and time.monotonic() < deadline:
                time.sleep(0.2)
            if self._endpoint(profile):
                raise BrowserError("Das Anbieter-Profil ist noch geöffnet. Bitte sein Fenster schließen und erneut versuchen.")

    def forget(self, provider_id):
        profile = (self.profile_root / provider_id).resolve()
        root = self.profile_root.resolve()
        if profile.parent != root or provider_id not in PROVIDERS:
            raise BrowserError("Ungültiges Anbieter-Profil.")
        if provider_id in self.sessions:
            self.close(provider_id)
        elif self._endpoint(profile):
            # Disconnect does not need to attach Playwright or start Chrome.
            # It also works while a browser is already shutting down.
            try:
                self._request_close(profile)
            except Exception:
                pass
            deadline = time.monotonic() + 5
            while self._endpoint(profile) and time.monotonic() < deadline:
                time.sleep(.2)
            if self._endpoint(profile):
                raise BrowserError("Das Anbieter-Fenster ist noch geöffnet. Bitte schließen und erneut trennen.")
        if profile.exists():
            try:
                shutil.rmtree(profile)
            except OSError:
                raise BrowserError("Das Anbieter-Fenster ist noch geöffnet. Bitte schließen und erneut trennen.") from None

    def shutdown(self):
        for provider_id in list(self.sessions):
            session = self.sessions[provider_id]
            if session.process is not None:
                self.close(provider_id)
            else:
                # A reattached profile may be a pre-existing user window. Detach
                # this CDP reader; explicit Trennen can still remove its profile.
                self.sessions.pop(provider_id)
                session.browser.close()
        if self.playwright:
            self.playwright.stop()
            self.playwright = None
