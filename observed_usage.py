"""Read structured identity/quota responses already received by the provider's own page.

No undocumented API calls are made and no tokens, identities or response bodies are saved.
Schema changes leave tracking unavailable instead of fabricating a measurement.
"""
from datetime import datetime
import re
from urllib.parse import urlsplit

from api_clients import UsageWindow
from subscription_usage import WINDOWS, percent, quota_stats, reset_iso
from providers import PROVIDERS


def reset_time(value):
    if not isinstance(value, str):
        return "Nicht verfügbar"
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone().strftime("%d.%m. %H:%M")
    except ValueError:
        return "Nicht verfügbar"


def claude_usage(payload):
    if not isinstance(payload, dict):
        return None
    windows = []
    for name, title in WINDOWS:
        data = payload.get(name)
        used = percent(data.get('utilization')) if isinstance(data, dict) else None
        windows.append(UsageWindow(name, title, used, reset_iso(data.get('resets_at')) if isinstance(data, dict) else None))
    if not any(w.used_percent is not None for w in windows):
        return None
    return quota_stats(windows, 'Claude-Abo')


def observation(provider_id, url, status, payload):
    """Return (identity_confirmed, usage). None means unrelated or unsupported response."""
    provider = PROVIDERS[provider_id]
    parsed = urlsplit(url)
    product_host = (urlsplit(provider.url).hostname or "").removeprefix("www.")
    host = (parsed.hostname or "").removeprefix("www.")
    if host != product_host:
        return None
    path = parsed.path.rstrip("/")
    auth_endpoint = False
    if provider_id in ("chatgpt", "perplexity") and path == "/api/auth/session":
        auth_endpoint = True
        if status == 200 and isinstance(payload, dict):
            user = payload.get("user")
            if payload == {} or ("user" in payload and (user is None or user == {})):
                return False, None
            if isinstance(user, dict) and any(isinstance(user.get(key), str) and bool(user[key].strip()) for key in ("id", "email")):
                return True, None
    elif provider_id == "chatgpt" and path == "/backend-api/me":
        auth_endpoint = True
        if status == 200 and isinstance(payload, dict):
            identity = payload.get("id")
            if isinstance(identity, str) and identity.strip():
                return True, None
    elif provider_id == "claude" and path == "/api/organizations":
        auth_endpoint = True
        if status == 200 and isinstance(payload, list):
            return (any(isinstance(row, dict) and isinstance(row.get("uuid"), str) and bool(row["uuid"]) for row in payload), None)
    elif provider_id == "claude" and re.fullmatch(r"/api/organizations/[^/]+/usage", path):
        auth_endpoint = True
        if status == 200 and (usage := claude_usage(payload)) is not None:
            return True, usage
    if auth_endpoint and status in (401, 403):
        return False, None
    return None


def relevant_response(provider_id, url):
    path = urlsplit(url).path.rstrip("/")
    if provider_id in ("chatgpt", "perplexity"):
        return path == "/api/auth/session" or (provider_id == "chatgpt" and path == "/backend-api/me")
    return provider_id == "claude" and (path == "/api/organizations" or bool(re.fullmatch(r"/api/organizations/[^/]+/usage", path)))
