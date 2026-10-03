"""Read account capacity through the documented Codex app-server protocol.

Uses the existing official Codex login. Never reads/copies auth files, starts a
chat, generates model tokens, consumes resets, or logs out another application.
"""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time

from api_clients import ProviderStats
from subscription_usage import codex_usage, empty_quota


class CodexError(RuntimeError):
    pass


def executable():
    for name in ('codex.exe', 'codex'):
        found = shutil.which(name)
        if found and Path(found).suffix.lower() not in ('.cmd', '.bat', '.ps1'):
            return found
    root = Path(os.environ.get('LOCALAPPDATA', '')) / 'OpenAI/Codex/bin'
    binaries = [p for p in root.glob('*/codex.exe') if p.is_file()]
    if binaries:
        return str(max(binaries, key=lambda p: p.stat().st_mtime))
    raise CodexError('Codex wurde nicht gefunden. Bitte die offizielle Codex-App installieren und dort mit deinem ChatGPT-Abo anmelden.')


class CodexUsageClient:
    def __init__(self, binary=None, timeout=30, factory=subprocess.Popen):
        self.binary, self.timeout, self.factory = binary, timeout, factory

    def check(self):
        process = None
        messages = queue.Queue()
        try:
            process = self.factory([self.binary or executable(), 'app-server', '--stdio',
                                    '-c', 'mcp_servers={}', '-c', 'analytics.enabled=false'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, encoding='utf-8', bufsize=1,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            def read():
                try:
                    for line in process.stdout:
                        if len(line) > 1_000_000:
                            continue
                        try:
                            message = json.loads(line)
                            if isinstance(message, dict):
                                messages.put(message)
                        except ValueError:
                            pass
                except (OSError, ValueError):
                    pass  # The owner may close stdout after a timed-out request.
                finally:
                    messages.put(None)
            reader = threading.Thread(target=read, name='codex-usage-reader', daemon=True)
            reader.start()
            deadline = time.monotonic() + self.timeout
            def send(message):
                process.stdin.write(json.dumps(message) + '\n')
                process.stdin.flush()
            def request(number, method, params=None):
                message = {'id': number, 'method': method}
                if params is not None:
                    message['params'] = params
                send(message)
                while True:
                    left = deadline - time.monotonic()
                    if left <= 0:
                        raise CodexError('Codex antwortet derzeit nicht. Bitte später erneut aktualisieren.')
                    try:
                        response = messages.get(timeout=left)
                    except queue.Empty:
                        raise CodexError('Codex antwortet derzeit nicht. Bitte später erneut aktualisieren.') from None
                    if response is None:
                        raise CodexError('Die Codex-Verbindung wurde beendet. Bitte Codex öffnen und erneut prüfen.')
                    if response.get('id') == number and 'method' not in response:
                        if response.get('error'):
                            raise CodexError('Codex konnte die Abo-Limits nicht abrufen. Bitte die Anmeldung in Codex prüfen und erneut aktualisieren.')
                        return response.get('result')
                    if 'id' in response and 'method' in response:
                        # This integration has no execution/approval surface.
                        send({'id': response['id'], 'error': {'code': -32601, 'message': 'Usage-only client'}})
            request(0, 'initialize', {'clientInfo': {'name': 'syp_tokentracker', 'title': 'TokenTracker', 'version': '2.3.0'}})
            send({'method': 'initialized', 'params': {}})
            account = request(1, 'account/read', {'refreshToken': False})
            identity = account.get('account') if isinstance(account, dict) else None
            if not isinstance(identity, dict) or identity.get('type') not in ('chatgpt', 'chatgptAuthTokens'):
                return empty_quota('Codex · ChatGPT-Abo', 'Bitte zuerst in der offiziellen Codex-App oder CLI mit deinem ChatGPT-Abo anmelden. Ein API-Schlüssel liefert keine Abo-Limits.', 'unauthorized')
            payload = request(2, 'account/rateLimits/read')
            stats = codex_usage(payload)
            if stats is None:
                return empty_quota('Codex · ChatGPT-Abo', 'Codex ist angemeldet, meldet aber keine lesbaren 5-Stunden-/Wochenwerte für dieses Konto.', authenticated=True)
            plan = identity.get('planType')
            if plan in ('free', 'go', 'plus', 'pro', 'team', 'business', 'enterprise', 'edu'):
                stats.source += ' · ' + plan.capitalize()
            return stats
        except CodexError as error:
            return empty_quota('Codex · ChatGPT-Abo', str(error), 'error')
        except (OSError, ValueError, BrokenPipeError):
            return empty_quota('Codex · ChatGPT-Abo', 'Die lokale Codex-Verbindung ist nicht bereit. Bitte Codex öffnen und erneut prüfen.', 'error')
        finally:
            if process is not None:
                try:
                    process.stdin.close()
                    process.wait(timeout=3)
                except (OSError, subprocess.TimeoutExpired):
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
                finally:
                    process.stdout.close()
