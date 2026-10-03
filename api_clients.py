"""Read-only provider checks. No completions and no inferred unlimited quotas."""
from dataclasses import dataclass, field
from datetime import datetime
import math
import requests

from providers import PROVIDERS


@dataclass
class UsageWindow:
    key: str
    title: str
    used_percent: float | None = None
    resets_at: str | None = None
    group: str = ""
    disabled: bool = False

    @property
    def remaining_percent(self):
        return None if self.used_percent is None or self.disabled else max(0, 100 - self.used_percent)


@dataclass
class ProviderStats:
    status: str = "ok"
    value: str = "Verbunden"
    label: str = "Kontostatus"
    detail: str = ""
    progress: float | None = None
    metrics: list[tuple[str, str]] = field(default_factory=list)
    checked_at: str = field(default_factory=lambda: datetime.now().astimezone().isoformat(timespec="seconds"))
    authenticated: bool = False
    windows: list[UsageWindow] = field(default_factory=list)
    stale: bool = False
    source: str = ""


def number(value):
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError("Invalid numeric response")
    return result


def check_api(provider_id, key, session=requests):
    provider = PROVIDERS[provider_id]
    if not key:
        return ProviderStats("unauthorized", "Nicht verbunden", detail="Bitte den Anbieter in den Einstellungen anmelden.")
    if provider_id in ("openai_usage", "anthropic_usage"):
        from organization_usage import check_organization_usage
        return check_organization_usage(provider_id, key, session)
    headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
    if provider_id == "anthropic_api":
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    elif provider_id == "gemini_api":
        headers = {"x-goog-api-key": key}
    try:
        response = session.get(provider.endpoint, headers=headers, timeout=(5, 15), allow_redirects=False)
        if provider_id == "gemini_api" and response.status_code in (400, 403):
            try:
                error = response.json().get("error", {})
                reasons = [row.get("reason") for row in error.get("details", []) if isinstance(row, dict)]
                if any(reason in ("API_KEY_INVALID", "API_KEY_EXPIRED") for reason in reasons):
                    return ProviderStats("unauthorized", "Schlüssel ungültig", detail="Der Gemini-Schlüssel ist ungültig oder abgelaufen. Bitte neu verbinden.")
            except (ValueError, TypeError, AttributeError):
                pass
        if response.status_code == 401:
            return ProviderStats("unauthorized", "Zugang abgelaufen", detail="Bitte erneut verbinden. Der Schlüssel wurde abgelehnt.")
        if response.status_code == 403:
            return ProviderStats("error", "Zugriff verweigert", detail="Berechtigungen oder Schlüssel prüfen; der Anbieter hat den Zugriff verweigert.")
        if response.status_code == 429:
            return ProviderStats("warning", "Zu viele Anfragen", detail="Der Anbieter begrenzt den Abruf. Bitte später aktualisieren.")
        if response.status_code != 200:
            return ProviderStats("error", "Abruf fehlgeschlagen", detail=f"Der Anbieter antwortet mit HTTP {response.status_code}.")
        payload = response.json()
        if not isinstance(payload, dict):
            raise ValueError
        if provider_id == "openrouter":
            data = payload["data"]
            usage = number(data["usage"])
            limit = data.get("limit")
            metrics = [("Verbrauch gesamt", f"${usage:,.4f}"),
                       ("Heute", f"${number(data['usage_daily']):,.4f}" if data.get("usage_daily") is not None else "Nicht verfügbar")]
            if limit is not None:
                limit = number(limit)
                remaining = number(data.get("limit_remaining", max(0, limit - usage)))
                return ProviderStats(status="warning" if remaining == 0 else "ok", value=f"${remaining:,.2f}", label="Verfügbares Schlüssellimit",
                                     detail="Das Budget dieses Schlüssels; das Kontoguthaben kann davon abweichen.",
                                     progress=min(usage / limit, 1) if limit > 0 else 1, metrics=metrics, authenticated=True)
            # An unlimited key budget says nothing about account credits.
            return ProviderStats(value=f"${usage:,.4f}", label="Verbrauch gesamt",
                                 detail="Kein Schlüssellimit gesetzt. Kontoguthaben im Anbieter-Dashboard prüfen.", metrics=metrics, authenticated=True)
        if provider_id == "deepseek_api":
            balances = payload["balance_infos"]
            if not isinstance(balances, list) or not balances:
                raise ValueError
            metrics = [(str(row["currency"]), f"{number(row['total_balance']):,.2f}") for row in balances]
            currency, amount = metrics[0]
            available = payload.get("is_available") is True
            return ProviderStats("ok" if available else "warning", f"{amount} {currency}", "API-Guthaben",
                                 "Direkt aus deinem DeepSeek-Konto.", metrics=metrics, authenticated=True)
        models = payload.get("models" if provider_id == "gemini_api" else "data")
        if not isinstance(models, list):
            raise ValueError
        return ProviderStats(value="Verbunden", label="Kein Tokenzähler verfügbar",
                             detail="Schlüssel geprüft. Dieser Zugang liefert keine Konto-Tokenstatistik. Nutzung im Anbieter-Dashboard öffnen.",
                             metrics=[("Tokenverbrauch", "Nicht abrufbar"), ("Tracking", "Anbieter-Dashboard")], authenticated=True)
    except requests.Timeout:
        return ProviderStats("error", "Zeitüberschreitung", detail="Der Anbieter antwortet zu langsam. Erneut versuchen.")
    except requests.RequestException:
        return ProviderStats("error", "Offline", detail="Verbindung fehlgeschlagen. Internetverbindung prüfen.")
    except (ValueError, KeyError, TypeError):
        return ProviderStats("error", "Antwort nicht lesbar", detail="Der Anbieter hat eine unerwartete Antwort geliefert.")
