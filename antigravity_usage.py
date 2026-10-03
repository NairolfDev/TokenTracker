"""Read Antigravity's own quota summary through its running local service.

The method and JSON schema are from the installed official Engine frontend:
exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary.
No Google OAuth files, API keys, prompts, credit operations or IDE settings are used.
"""
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import warnings

import requests
from urllib3.exceptions import InsecureRequestWarning

from api_clients import UsageWindow
from subscription_usage import empty_quota, percent, quota_stats, reset_iso, window_specs


QUOTA_METHOD = '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary'
SOURCE = 'Antigravity · lokaler Quota-Dienst'
BUCKETS = {
    'gemini-5h': ('gemini_five_hour', '5h'),
    'gemini-weekly': ('gemini_seven_day', 'weekly'),
    '3p-5h': ('claude_gpt_five_hour', '5h'),
    '3p-weekly': ('claude_gpt_seven_day', 'weekly'),
}


def antigravity_usage(payload):
    """Known bucket IDs identify the model pool; `window` confirms its duration."""
    response = payload.get('response') if isinstance(payload, dict) else None
    if not isinstance(response, dict):
        return None
    buckets = list(response.get('buckets', [])) if isinstance(response.get('buckets'), list) else []
    groups = response.get('groups', [])
    if isinstance(groups, list):
        for group in groups[:16]:
            if isinstance(group, dict) and isinstance(group.get('buckets'), list):
                buckets.extend(group['buckets'][:32])
    found, duplicates = {}, set()
    specs = {key: (title, group) for key, title, group in window_specs('antigravity')}
    for bucket in buckets[:128]:
        if not isinstance(bucket, dict) or not isinstance(bucket.get('bucketId'), str):
            continue
        mapping = BUCKETS.get(bucket['bucketId'])
        if not mapping:
            continue
        key, duration = mapping
        if bucket.get('window') not in (None, duration):
            continue
        disabled = bucket.get('disabled') is True
        fraction = percent(bucket.get('remainingFraction'))
        # remainingAmount is a separate oneof field, never a fraction or token balance.
        if not disabled and (fraction is None or fraction > 1):
            continue
        title, group = specs[key]
        window = UsageWindow(key, title, None if disabled else round(100 - fraction * 100, 2),
                             reset_iso(bucket.get('resetTime')), group, disabled)
        if key in found and found[key] != window:
            duplicates.add(key)
        else:
            found[key] = window
    for key in duplicates:
        found.pop(key, None)
    if not found:
        return None
    windows = [found.get(key, UsageWindow(key, title, group=group))
               for key, title, group in window_specs('antigravity')]
    stats = quota_stats(windows, SOURCE)
    stats.detail = ('Verbleibende Antigravity-Kapazität je Modellgruppe. Limits und Reset-Zeiten '
                    'stammen aus deiner laufenden Antigravity-Anmeldung.')
    if any(w.disabled for w in windows):
        stats.detail += ' Nicht verfügbare Fenster sind im aktuellen Tarif deaktiviert.'
    if len(found) < len(windows):
        stats.detail += ' Nicht gemeldete Fenster bleiben unbekannt.'
    return stats


@dataclass(frozen=True)
class LocalServer:
    pid: int
    port: int
    csrf: str = field(repr=False)


def _flag(command, name):
    match = re.search(r'(?:^|\s)--' + re.escape(name) + r'(?:=|\s+)(?:"([^"\r\n]*)"|([^\s"]+))', command)
    return (match.group(1) if match.group(1) is not None else match.group(2)) if match else None


def servers_from_processes(rows, netstat):
    """Only Antigravity Engine processes and ports owned by those PIDs qualify."""
    rows = rows if isinstance(rows, list) else [rows]
    listeners = {}
    for line in netstat.splitlines():
        parts = line.split()
        if len(parts) != 5 or parts[0] != 'TCP' or parts[3] != 'LISTENING':
            continue
        try:
            pid, port = int(parts[4]), int(parts[1].rsplit(':', 1)[1])
            if 1 <= port <= 65535:
                listeners.setdefault(pid, set()).add(port)
        except ValueError:
            continue
    servers = []
    for row in rows[:16]:
        if not isinstance(row, dict):
            continue
        path, command, pid = row.get('ExecutablePath'), row.get('CommandLine'), row.get('ProcessId')
        if not isinstance(path, str) or not isinstance(command, str) or type(pid) is not int:
            continue
        # Normalize Windows paths independently of the platform, also for tests.
        parts = path.replace('\\', '/').lower().split('/')
        if len(parts) < 5 or parts[-4:] != ['antigravity', 'resources', 'bin', 'language_server.exe']:
            continue
        if _flag(command, 'override_ide_name') != 'antigravity':
            continue
        csrf = _flag(command, 'csrf_token')
        if not csrf or not re.fullmatch(r'[A-Za-z0-9_.-]{8,512}', csrf):
            continue
        owned_ports = sorted(listeners.get(pid, ()))
        configured = _flag(command, 'https_server_port')
        if configured and configured.isdigit() and int(configured) in owned_ports:
            owned_ports.remove(int(configured))
            owned_ports.insert(0, int(configured))
        servers.extend(LocalServer(pid, port, csrf) for port in owned_ports[:4])
    return servers


def discover_servers():
    if sys.platform != 'win32':
        return []
    system = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32'
    query = ("Get-CimInstance Win32_Process -Filter \"Name='language_server.exe'\" | "
             "Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress")
    options = dict(capture_output=True, text=True, encoding='utf-8', errors='replace',
                   timeout=12, check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    # Command lines remain private in memory. Never log/persist the local CSRF value.
    result = subprocess.run([str(system / 'WindowsPowerShell/v1.0/powershell.exe'),
                             '-NoProfile', '-NonInteractive', '-Command', query], **options)
    if not result.stdout.strip():
        return []
    rows = json.loads(result.stdout)
    netstat = subprocess.run([str(system / 'netstat.exe'), '-ano', '-p', 'tcp'], **options)
    return servers_from_processes(rows, netstat.stdout)


class AntigravityUsageClient:
    def __init__(self, finder=discover_servers, session_factory=requests.Session):
        self.finder, self.session_factory = finder, session_factory

    def check(self):
        def unavailable(value, detail, status='paused'):
            stats = empty_quota(SOURCE, detail, status, provider_id='antigravity')
            stats.value = value
            return stats

        try:
            servers = self.finder()
        except (OSError, ValueError, subprocess.SubprocessError):
            return unavailable('Abruf pausiert', 'Antigravity konnte nicht lokal erkannt werden. Antigravity öffnen und erneut prüfen.')
        if not servers:
            return unavailable('Antigravity öffnen', 'Antigravity starten und dort anmelden. Anschließend hier »Prüfen« wählen.')
        unauthorized, unsupported = False, False
        with self.session_factory() as session:
            session.trust_env = False  # No proxy may receive the local CSRF header.
            for server in servers[:8]:
                if (type(server.port) is not int or not 1 <= server.port <= 65535
                        or not re.fullmatch(r'[A-Za-z0-9_.-]{8,512}', server.csrf)):
                    continue
                try:
                    # Antigravity uses a self-signed loopback certificate in its own frontend.
                    # This exception is confined to this fixed HTTPS loopback endpoint.
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore', InsecureRequestWarning)
                        response = session.post(f'https://127.0.0.1:{server.port}{QUOTA_METHOD}',
                                                json={'forceRefresh': True},
                                                headers={'x-codeium-csrf-token': server.csrf,
                                                         'Connect-Protocol-Version': '1'},
                                                timeout=(2, 10), verify=False, allow_redirects=False)
                    if response.status_code in (401, 403):
                        unauthorized = True
                        continue
                    if response.status_code != 200 or len(response.content) > 1024 * 1024:
                        continue
                    payload = response.json()
                    if stats := antigravity_usage(payload):
                        return stats
                    unsupported = True
                except (requests.RequestException, ValueError, TypeError):
                    continue
        if unsupported:
            return unavailable('Limits nicht lesbar', 'Antigravity meldet derzeit keine unterstützten Quota-Fenster. In Antigravity → Models → View Usage prüfen.', 'error')
        if unauthorized:
            # Local CSRF failures can also be a server restart; they never prove an account logout.
            return unavailable('Anmeldung prüfen', 'Antigravity erneut öffnen und die Anmeldung dort prüfen. Danach hier aktualisieren.')
        return unavailable('Abruf pausiert', 'Der lokale Antigravity-Dienst antwortet nicht. Antigravity öffnen und erneut prüfen.')


def open_antigravity():
    """Open the installed app explicitly; polling never starts or reloads it."""
    for root in (os.environ.get('LOCALAPPDATA', ''), os.environ.get('ProgramFiles', '')):
        if not root:
            continue
        base = Path(root)
        candidates = [base / 'Programs/Antigravity/Antigravity.exe', base / 'Antigravity/Antigravity.exe']
        for path in candidates:
            if path.is_file():
                subprocess.Popen([str(path)], creationflags=subprocess.CREATE_NO_WINDOW)
                return True
    return False
