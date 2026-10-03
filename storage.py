"""Atomic settings and user-bound encrypted credentials, never plaintext API keys."""
import base64
import copy
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import threading

from providers import PROVIDERS

APP_DIR = Path(__file__).resolve().parent
DATA_DIR = APP_DIR / ".tracker"


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


class StorageError(RuntimeError):
    pass


def protect(raw: bytes, decrypt=False) -> bytes:
    if os.name != "nt":
        raise StorageError("Die sichere Schlüsselspeicherung benötigt Windows.")

    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]

    buffer = ctypes.create_string_buffer(raw)
    source = Blob(len(raw), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if decrypt:
        function = crypt.CryptUnprotectData
        function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                             ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        arguments = (ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        function = crypt.CryptProtectData
        function.argtypes = [ctypes.POINTER(Blob), wintypes.LPCWSTR, ctypes.c_void_p,
                             ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        arguments = (ctypes.byref(source), "SYP TokenTracker", None, None, None, 1, ctypes.byref(target))
    function.restype = wintypes.BOOL
    if not function(*arguments):
        raise StorageError("Der Windows-Schlüsselspeicher konnte nicht geöffnet werden.")
    try:
        return ctypes.string_at(target.data, target.size)
    finally:
        kernel.LocalFree(ctypes.cast(target.data, ctypes.c_void_p))


class CredentialVault:
    def __init__(self, path=DATA_DIR / "credentials.json"):
        self.path = Path(path)
        self.lock = threading.RLock()

    def _read(self):
        if not self.path.exists():
            return {}
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(value, dict):
                raise ValueError
            return value
        except (ValueError, OSError):
            raise StorageError("Die Schlüsseldatei ist beschädigt. Bitte den Anbieter erneut verbinden.") from None

    def get(self, provider_id):
        with self.lock:
            encoded = self._read().get(provider_id)
            if not encoded:
                return ""
            try:
                return protect(base64.b64decode(encoded, validate=True), decrypt=True).decode("utf-8")
            except (ValueError, UnicodeError):
                raise StorageError("Der gespeicherte Schlüssel ist nicht lesbar.") from None

    def set(self, provider_id, secret):
        if provider_id not in PROVIDERS or not isinstance(secret, str) or not secret.strip():
            raise StorageError("Bitte einen gültigen Schlüssel angeben.")
        with self.lock:
            data = self._read()
            data[provider_id] = base64.b64encode(protect(secret.strip().encode())).decode("ascii")
            atomic_json(self.path, data)

    def delete(self, provider_id):
        with self.lock:
            data = self._read()
            data.pop(provider_id, None)
            atomic_json(self.path, data)


def defaults():
    return {
        "version": 2, "theme": "Dark", "refresh_minutes": 5, "always_on_top": False,
        "compact_position": None,
        "providers": {pid: {"enabled": True, "connected": False, "method": provider.kind}
                      for pid, provider in PROVIDERS.items()},
    }


class SettingsStore:
    def __init__(self, path=APP_DIR / "config.json", vault=None):
        self.path = Path(path)
        self.vault = vault or CredentialVault()
        self.warning = ""
        self.writable = True
        self.data = self._load()
        from usage_cache import UsageCache
        self.usage_cache = UsageCache(self.path.parent / '.tracker/usage.json')

    def _load(self):
        cfg = defaults()
        if not self.path.exists():
            return cfg
        try:
            original = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(original, dict):
                raise ValueError
        except (ValueError, OSError):
            self.writable = False
            self.warning = "Die Einstellungen sind nicht lesbar. Standardwerte sind aktiv; die Originaldatei bleibt erhalten."
            return cfg
        cfg["theme"] = original.get("theme") if original.get("theme") in ("Dark", "Light", "System") else "Dark"
        cfg["always_on_top"] = original.get("always_on_top") is True
        position = original.get("compact_position")
        if (isinstance(position, list) and len(position) == 2
                and all(isinstance(n, int) and not isinstance(n, bool) and abs(n) < 100000 for n in position)):
            cfg["compact_position"] = position
        interval = str(original.get("refresh_minutes", 5))
        cfg["refresh_minutes"] = int(interval) if interval in ("1", "5", "10", "15", "30", "60") else 0
        previous = original.get("providers", {})
        if isinstance(previous, dict):
            for pid, entry in previous.items():
                if pid in cfg["providers"] and isinstance(entry, dict):
                    cfg["providers"][pid]["enabled"] = entry.get("enabled", True) is True
                    cfg["providers"][pid]["connected"] = entry.get("connected", False) is True
        # Migrate the old key only after encryption succeeds. The old "ready" file proves no login.
        legacy = original.get("openrouter_key", "")
        if isinstance(legacy, str) and legacy.strip():
            try:
                self.vault.set("openrouter", legacy)
                atomic_json(self.path, cfg)
            except (StorageError, OSError):
                self.writable = False
                self.warning = "Der bisherige OpenRouter-Schlüssel konnte nicht sicher übernommen werden. Die Originaldatei bleibt erhalten."
        return cfg

    def save(self):
        if not self.writable:
            raise StorageError("Die Originalkonfiguration bleibt erhalten, bis der Lesefehler behoben ist.")
        atomic_json(self.path, self.data)

    def snapshot(self):
        return copy.deepcopy(self.data)

    def visible(self):
        return [pid for pid, state in self.data["providers"].items() if state["enabled"] and state["connected"]]
