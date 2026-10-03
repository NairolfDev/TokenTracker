"""Subscription capacity is a reported percentage, never an invented token balance."""
from datetime import datetime, timezone, timedelta
import math
import re

from api_clients import ProviderStats, UsageWindow


WINDOWS = (('five_hour', '5 Stunden'), ('seven_day', 'Woche'))
ANTIGRAVITY_WINDOWS = (
    ('gemini_five_hour', '5 Stunden', 'Gemini'),
    ('gemini_seven_day', 'Woche', 'Gemini'),
    ('claude_gpt_five_hour', '5 Stunden', 'Claude / GPT'),
    ('claude_gpt_seven_day', 'Woche', 'Claude / GPT'),
)


def window_specs(provider_id=None):
    return ANTIGRAVITY_WINDOWS if provider_id == 'antigravity' else tuple((key, title, '') for key, title in WINDOWS)


def percent(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        value = float(value)
        return value if math.isfinite(value) and 0 <= value <= 100 else None
    except ValueError:
        return None


def reset_iso(value):
    try:
        if isinstance(value, bool):
            return None
        if isinstance(value, (int, float)) and math.isfinite(value):
            return datetime.fromtimestamp(value, timezone.utc).isoformat()
        if isinstance(value, str):
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
            if parsed.tzinfo is not None:
                return parsed.astimezone(timezone.utc).isoformat()
    except (ValueError, OverflowError, OSError):
        pass
    return None


def reset_label(window, now=None):
    if not window.resets_at:
        return 'Reset nicht gemeldet'
    try:
        reset = datetime.fromisoformat(window.resets_at).astimezone()
        current = now or datetime.now().astimezone()
        if reset <= current:
            return 'Reset fällig · aktualisieren'
        return 'Reset ' + reset.strftime('%H:%M' if reset.date() == current.date() else '%d.%m. %H:%M')
    except ValueError:
        return 'Reset nicht gemeldet'


def remaining_label(window):
    if window.disabled:
        return 'Nicht verfügbar'
    remaining = window.remaining_percent
    return 'Nicht gemeldet' if remaining is None else f'{remaining:g}% übrig'


def quota_stats(windows, source, authenticated=True):
    measured = [window for window in windows if window.used_percent is not None and not window.disabled]
    tightest = min(measured, key=lambda w: w.remaining_percent) if measured else None
    exhausted = any(window.remaining_percent == 0 for window in measured)
    warning = any(window.remaining_percent <= 10 for window in measured)
    return ProviderStats('warning' if warning else 'ok' if measured else 'unverified',
                         f'{tightest.remaining_percent:g}%' if tightest else '—',
                         f'{tightest.group + " · " if tightest.group else ""}{tightest.title} übrig' if tightest else 'Abo-Limits noch nicht gelesen',
                         'Mindestens ein Abo-Zeitfenster ist ausgeschöpft.' if exhausted else
                         'Verbleibende Abo-Kapazität aus der Nutzungsübersicht. Die Prozentwerte sind keine feste Tokenanzahl.',
                         progress=tightest.remaining_percent / 100 if tightest else None,
                         metrics=[((w.group + ' · ' if w.group else '') + w.title + ' übrig', remaining_label(w)) for w in windows],
                         authenticated=authenticated, windows=windows, source=source)


def empty_quota(source, detail='', status='unverified', authenticated=False, provider_id=None):
    result = quota_stats([UsageWindow(key, title, group=group) for key, title, group in window_specs(provider_id)], source, authenticated)
    result.detail, result.status = detail or result.detail, status
    return result


def codex_usage(payload):
    if not isinstance(payload, dict):
        return None
    buckets = payload.get('rateLimitsByLimitId')
    snapshot = buckets.get('codex') if isinstance(buckets, dict) else None
    if not isinstance(snapshot, dict):
        snapshot = payload.get('rateLimits')
    if not isinstance(snapshot, dict) or snapshot.get('limitId') not in (None, 'codex'):
        return None
    reported = {}
    for name in ('primary', 'secondary'):
        row = snapshot.get(name)
        if not isinstance(row, dict):
            continue
        duration = row.get('windowDurationMins')
        key = 'five_hour' if duration == 300 else 'seven_day' if duration == 10080 else None
        if key and (used := percent(row.get('usedPercent'))) is not None:
            reported[key] = UsageWindow(key, dict(WINDOWS)[key], used, reset_iso(row.get('resetsAt')))
    if not reported:
        return None
    result = quota_stats([reported.get(key, UsageWindow(key, title)) for key, title in WINDOWS], 'Codex · ChatGPT-Abo')
    if reported.get('five_hour') is None:
        result.detail = 'Codex meldet für dieses Konto kein 5-Stunden-Fenster. Das Wochenlimit wird separat angezeigt.'
    return result


def page_usage(text, provider_id):
    """Only call on a dedicated usage page/dialog, never on arbitrary chat text."""
    headings = {
        'claude': (r'Current session|Aktuelle Sitzung|5[- ](?:hour|Stunden)',
                   r'All models|Alle Modelle|Weekly (?:limit|usage)|Wochenlimit'),
        'gemini_chat': (r'Current usage|Aktuelle Nutzung|5[-\s\u2011\u2013](?:hour|Stunden)|five[- ]hour|Fünf[- ]Stunden',
                        r'Weekly (?:limit|usage)|Weekly|Wöchentlich(?:es Limit)?|Wochenlimit|Woche'),
    }
    if provider_id not in headings:
        return None
    found = {}
    patterns = headings[provider_id]
    for i, (key, title) in enumerate(WINDOWS):
        heading = re.search(r'(?:' + patterns[i] + r')', text, re.I)
        if not heading:
            continue
        segment = text[heading.end():heading.end() + 350]
        other = re.search(r'(?:' + patterns[1-i] + r')', segment, re.I)
        if other:
            segment = segment[:other.start()]
        value = re.search(r'(\d{1,3}(?:[.,]\d+)?)\s*%\s*(used|verbraucht|genutzt|verwendet|remaining|left|übrig|verbleibend)', segment, re.I)
        if not value:
            # Some dashboards put the direction before the number.
            value = re.search(r'(used|verbraucht|genutzt|verwendet|remaining|left|übrig|verbleibend)\s*[:\s]*(\d{1,3}(?:[.,]\d+)?)\s*%', segment, re.I)
            if not value:
                continue
            direction, raw = value.group(1), value.group(2)
        else:
            raw, direction = value.group(1), value.group(2)
        used = percent(raw.replace(',', '.'))
        if used is None:
            continue
        if direction.lower() in ('remaining', 'left', 'übrig', 'verbleibend'):
            used = 100 - used
        # A relative reset is meaningful only inside this window's own section.
        reset = re.search(r'(?:resets? in|reset in|zurückgesetzt in)\s*([^\n]{1,70})', segment, re.I)
        resets_at = None
        if provider_id == 'gemini_chat':
            from gemini_usage import reset_at
            resets_at = reset_at(segment, key)
        if reset:
            units = re.findall(r'(\d+)\s*(days?|hours?|hrs?|minutes?|mins?|Tage?n?|Stunden?|Minuten?)\b', reset.group(1), re.I)
            seconds = 0
            for count, unit in units:
                multiplier = 86400 if unit.lower().startswith(('day', 'tag')) else 3600 if unit.lower().startswith(('hour', 'hr', 'stund')) else 60
                seconds += int(count) * multiplier
            if units and 0 < seconds <= 7 * 86400:
                resets_at = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        found[key] = UsageWindow(key, title, used, resets_at)
    if not found:
        return None
    return quota_stats([found.get(key, UsageWindow(key, title)) for key, title in WINDOWS],
                       'Claude-Abo' if provider_id == 'claude' else 'Gemini-Abo')
