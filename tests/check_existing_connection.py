"""Read-only account check and safe migration; never print a credential."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from api_clients import check_api
from storage import SettingsStore


store = SettingsStore()
print("Settings migration:", "warning" if store.warning else "ok")
key = store.vault.get("openrouter")
if key:
    result = check_api("openrouter", key)
    print("Existing OpenRouter connection:", result.status, "verified" if result.authenticated else "not verified")
    if result.authenticated:
        store.data["providers"]["openrouter"]["connected"] = True
        store.save()
    else:
        print("Connection detail:", result.detail)
else:
    print("No existing OpenRouter key")
