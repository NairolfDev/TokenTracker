"""Background operations report through a queue; Tk widgets stay on the main thread."""
from concurrent.futures import ThreadPoolExecutor
import queue
import threading

from api_clients import ProviderStats, check_api
from browser_sessions import BrowserSessions
from codex_usage import CodexUsageClient
from antigravity_usage import AntigravityUsageClient
from openrouter_auth import AuthError, OpenRouterLogin
from providers import PROVIDERS
from storage import CredentialVault, StorageError


class ConnectionManager:
    def __init__(self, vault=None, browsers=None, codex=None, antigravity=None):
        self.vault = vault or CredentialVault()
        self.browsers = browsers or BrowserSessions()
        self.codex = codex or CodexUsageClient()
        self.antigravity = antigravity or AntigravityUsageClient()
        self.events = queue.Queue()
        self.api_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="provider-api")
        self.browser_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="provider-browser")
        self.pending = set()
        self.generations = {pid: 0 for pid in PROVIDERS}
        self.logins = {}
        self.lock = threading.RLock()
        self.closed = False

    def busy(self, provider_id):
        with self.lock:
            return provider_id in self.pending

    def _submit(self, provider_id, operation, function, browser=False):
        with self.lock:
            if self.closed or provider_id in self.pending:
                return False
            generation = self.generations[provider_id]
            self.pending.add(provider_id)
        pool = self.browser_pool if browser else self.api_pool

        def run():
            with self.lock:
                if self.closed or self.generations[provider_id] != generation:
                    self.pending.discard(provider_id)
                    if not self.closed:
                        self.events.put((provider_id, "cancelled", None))
                    return
            try:
                result = function()
            except (StorageError, AuthError) as error:
                result = ProviderStats("error", "Verbindung fehlgeschlagen", detail=str(error))
            except Exception:
                result = ProviderStats("error", "Vorgang fehlgeschlagen", detail="Bitte erneut versuchen. Die Verbindung konnte nicht abgeschlossen werden.")
            with self.lock:
                self.pending.discard(provider_id)
                if not self.closed and self.generations[provider_id] == generation:
                    self.events.put((provider_id, operation, result))
                elif not self.closed:
                    self.events.put((provider_id, "cancelled", None))
        pool.submit(run)
        return True

    def refresh(self, provider_id, login_poll=False, manual=False):
        browser = PROVIDERS[provider_id].kind == "browser"
        return self._submit(provider_id, "poll" if login_poll else "refresh",
                            lambda: self.browsers.check(provider_id, refresh=not login_poll, login_poll=login_poll, manual=manual) if browser
                            else self.codex.check() if PROVIDERS[provider_id].kind == 'codex'
                            else self.antigravity.check() if PROVIDERS[provider_id].kind == 'antigravity'
                            else check_api(provider_id, self.vault.get(provider_id)), browser=browser)

    def connect_codex(self):
        return self._submit('chatgpt', 'connect', self.codex.check)

    def connect_antigravity(self):
        return self._submit('antigravity', 'connect', self.antigravity.check)

    def connect_browser(self, provider_id):
        return self._submit(provider_id, "login", lambda: self.browsers.open_login(provider_id), browser=True)

    def connect_key(self, provider_id, key):
        generation = self.generations[provider_id]

        def validate():
            result = check_api(provider_id, key)
            with self.lock:
                if not self.closed and self.generations[provider_id] == generation and result.authenticated:
                    self.vault.set(provider_id, key)
            return result
        return self._submit(provider_id, "connect", validate)

    def connect_openrouter(self):
        if self.busy("openrouter"):
            return False
        login = OpenRouterLogin()
        self.logins["openrouter"] = login
        generation = self.generations["openrouter"]

        def authorize():
            try:
                key = login.run(on_ready=lambda: self.events.put(("openrouter", "oauth_wait", None)))
                if login.cancelled.is_set():
                    raise AuthError("Anmeldung abgebrochen.")
                result = check_api("openrouter", key)
                with self.lock:
                    if (not self.closed and self.generations["openrouter"] == generation
                            and not login.cancelled.is_set() and result.authenticated):
                        self.vault.set("openrouter", key)
                return result
            finally:
                self.logins.pop("openrouter", None)
        return self._submit("openrouter", "connect", authorize)

    def cancel_login(self, provider_id):
        with self.lock:
            self.generations[provider_id] += 1
            if login := self.logins.get(provider_id):
                login.cancel()

    def disconnect(self, provider_id):
        if self.busy(provider_id):
            return False
        with self.lock:
            self.generations[provider_id] += 1

        def remove():
            if PROVIDERS[provider_id].kind == "browser":
                self.browsers.forget(provider_id)
            elif PROVIDERS[provider_id].kind not in ('codex', 'antigravity'):
                self.vault.delete(provider_id)
            return ProviderStats("disconnected", "Getrennt", detail="Die lokale Verbindung wurde entfernt.")
        return self._submit(provider_id, "disconnect", remove, browser=PROVIDERS[provider_id].kind == "browser")

    def shutdown(self):
        with self.lock:
            self.closed = True
            for login in self.logins.values():
                login.cancel()
        self.api_pool.shutdown(wait=False, cancel_futures=True)
        self.browser_pool.submit(self.browsers.shutdown)
        self.browser_pool.shutdown(wait=False, cancel_futures=False)
