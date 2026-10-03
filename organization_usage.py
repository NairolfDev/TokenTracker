"""Optional official usage reports. Only read requests; never falls back to paid inference."""
from datetime import datetime, timedelta, timezone
import requests

from api_clients import ProviderStats
from providers import PROVIDERS


def token_count(value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("Invalid token count")
    return value


def totals(provider_id, payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list) or not isinstance(payload.get("has_more"), bool):
        raise ValueError("Invalid usage report")
    incoming = outgoing = 0
    for bucket in payload["data"]:
        if not isinstance(bucket, dict) or not isinstance(bucket.get("results"), list):
            raise ValueError("Invalid time bucket")
        for row in bucket["results"]:
            if not isinstance(row, dict):
                raise ValueError("Invalid usage result")
            outgoing += token_count(row["output_tokens"])
            if provider_id == "openai_usage":
                # OpenAI input_tokens already includes cache hits and cache writes.
                incoming += token_count(row["input_tokens"])
            else:
                creation = row["cache_creation"]
                incoming += (token_count(row["uncached_input_tokens"]) + token_count(row["cache_read_input_tokens"])
                             + token_count(creation["ephemeral_5m_input_tokens"]) + token_count(creation["ephemeral_1h_input_tokens"]))
    return incoming, outgoing


def check_organization_usage(provider_id, key, session=requests, now=None):
    provider = PROVIDERS[provider_id]
    now = now or datetime.now(timezone.utc)
    now = now.astimezone(timezone.utc)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=6)
    headers = {"Authorization": f"Bearer {key}", "Accept": "application/json", "User-Agent": "SYP-TokenTracker/2.1"}
    params = {"bucket_width": "1d", "limit": 31}
    if provider_id == "openai_usage":
        params.update(start_time=int(start.timestamp()), end_time=int(now.timestamp()))
    else:
        headers = {"x-api-key": key, "anthropic-version": "2023-06-01", "Accept": "application/json", "User-Agent": "SYP-TokenTracker/2.1"}
        params.update(starting_at=start.isoformat(), ending_at=now.isoformat())
    incoming = outgoing = 0
    seen = set()
    try:
        for _ in range(10):
            response = session.get(provider.endpoint, headers=headers, params=dict(params), timeout=(5, 15), allow_redirects=False)
            if response.status_code == 401:
                return ProviderStats("unauthorized", "Zugang abgelehnt", detail="Der Nutzungszugang ist ungültig oder abgelaufen. Bitte neu verbinden.")
            if response.status_code == 403:
                return ProviderStats("error", "Leseberechtigung fehlt", detail="Ein normaler Projektschlüssel reicht nicht aus. Admin-Zugang mit Leserecht für Organisations-Nutzungsdaten verwenden.")
            if response.status_code == 429:
                return ProviderStats("warning", "Abruf begrenzt", detail="Der Anbieter begrenzt Nutzungsabfragen. Bitte später erneut prüfen.")
            if response.status_code != 200:
                return ProviderStats("error", "Nutzung nicht abrufbar", detail=f"Der Anbieter antwortet mit HTTP {response.status_code}. Keine unvollständige Summe angezeigt.")
            payload = response.json()
            page_in, page_out = totals(provider_id, payload)
            incoming += page_in
            outgoing += page_out
            if not payload["has_more"]:
                return ProviderStats(value=f"{incoming + outgoing:,}", label="Tokens · 7 Tage",
                                     detail=f"Modellanfragen der API-Organisation seit {start:%d.%m.} UTC. Anbieterwerte können verzögert sein.",
                                     metrics=[("Input inkl. Cache", f"{incoming:,}"), ("Output", f"{outgoing:,}")], authenticated=True)
            cursor = payload.get("next_page")
            if not isinstance(cursor, str) or not cursor or cursor in seen:
                raise ValueError("Invalid pagination")
            seen.add(cursor)
            params["page"] = cursor
        raise ValueError("Incomplete report")
    except requests.Timeout:
        return ProviderStats("error", "Zeitüberschreitung", detail="Der Nutzungsbericht konnte nicht vollständig geladen werden. Erneut versuchen.")
    except requests.RequestException:
        return ProviderStats("error", "Offline", detail="Der Nutzungsbericht ist momentan nicht erreichbar.")
    except (ValueError, KeyError, TypeError):
        return ProviderStats("error", "Nutzungsdaten nicht lesbar", detail="Der Bericht ist unvollständig oder hat ein geändertes Format. Es wird keine geschätzte Tokenzahl angezeigt.")
