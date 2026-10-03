"""Persist only measured percentages/reset times; cached data never proves a login."""
from datetime import datetime
import json
from pathlib import Path

from api_clients import UsageWindow
from subscription_usage import percent, quota_stats, reset_iso, window_specs


class UsageCache:
    def __init__(self, path):
        self.path = Path(path)
        try:
            value = json.loads(self.path.read_text(encoding='utf-8'))
            self.data = value.get('providers', {}) if isinstance(value, dict) and value.get('version') == 1 else {}
            if not isinstance(self.data, dict):
                self.data = {}
        except (OSError, ValueError):
            self.data = {}

    def load(self):
        stats = {}
        for pid, row in self.data.items():
            if pid not in ('claude', 'chatgpt', 'gemini_chat', 'antigravity') or not isinstance(row, dict):
                continue
            try:
                checked = datetime.fromisoformat(row['checked_at'])
                if checked.tzinfo is None:
                    continue
                windows = row.get('windows')
                if not isinstance(windows, dict):
                    continue
                parsed = []
                for key, title, group in window_specs(pid):
                    window = windows.get(key, {})
                    if not isinstance(window, dict):
                        window = {}
                    disabled = window.get('disabled') is True
                    parsed.append(UsageWindow(key, title, None if disabled else percent(window.get('used_percent')),
                                              reset_iso(window.get('resets_at')), group, disabled))
                if not any(w.used_percent is not None for w in parsed):
                    continue
                source = row.get('source', '')
                source = source[:80] if isinstance(source, str) else ''
                result = quota_stats(parsed, source, authenticated=False)
                result.checked_at, result.stale, result.status = checked.isoformat(), True, 'paused'
                result.detail = 'Gespeicherter Messstand. Wird beim nächsten erfolgreichen Abruf aktualisiert.'
                stats[pid] = result
            except (ValueError, TypeError, KeyError):
                continue
        return stats

    def put(self, pid, stats):
        if (pid not in ('claude', 'chatgpt', 'gemini_chat', 'antigravity') or not stats.authenticated or stats.stale
                or not any(w.used_percent is not None for w in stats.windows)):
            return
        self.data[pid] = {'checked_at': stats.checked_at, 'source': stats.source,
                          'windows': {w.key: {'used_percent': w.used_percent, 'resets_at': w.resets_at, 'disabled': w.disabled}
                                      for w in stats.windows if w.key in {key for key, _, _ in window_specs(pid)}}}
        self._save()

    def delete(self, pid):
        if pid in self.data:
            self.data.pop(pid)
            self._save()

    def _save(self):
        from storage import atomic_json
        atomic_json(self.path, {'version': 1, 'providers': self.data})
