"""Native UI checks with isolated state, no real accounts or external requests."""
from pathlib import Path
import queue
import sys
import tempfile
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from api_clients import ProviderStats
from main import TokenTrackerApp
from storage import SettingsStore
from observed_usage import claude_usage
from subscription_usage import codex_usage, page_usage
from antigravity_usage import antigravity_usage
from test_antigravity_usage import quotas


class TestVault:
    def get(self, pid):
        return ""


class TestManager:
    def __init__(self):
        self.events = queue.Queue()
        self.refresh_calls = []
        self.codex_connections = 0
        self.antigravity_connections = 0

    def busy(self, pid):
        return False

    def refresh(self, pid, login_poll=False, manual=False):
        self.refresh_calls.append(pid)
        return True

    def cancel_login(self, pid):
        pass

    def connect_codex(self):
        self.codex_connections += 1
        return True

    def connect_antigravity(self):
        self.antigravity_connections += 1
        return True

    def shutdown(self):
        pass


def run():
    with tempfile.TemporaryDirectory() as directory:
        store = SettingsStore(Path(directory) / "config.json", TestVault())
        manager = TestManager()
        app = TokenTrackerApp(store=store, manager=manager, auto_start=False)
        callback_errors = []
        app.report_callback_exception = lambda *args: callback_errors.append(args)
        app.update()
        assert store.visible() == [], "Disconnected providers must start hidden"

        manager.events.put(("claude", "login", ProviderStats("pending", "Anmeldung offen")))
        app.drain_events()
        assert not store.data["providers"]["claude"]["connected"], "Opening a browser is not a login"

        for pid, stats in (
            ("openrouter", ProviderStats(value="$18.42", label="Verfügbares Schlüssellimit",
               detail="Testdaten für die visuelle Prüfung.", progress=.26,
               metrics=[("Verbrauch gesamt", "$6.5800"), ("Heute", "$0.3200")], authenticated=True)),
            ("claude", claude_usage({'five_hour': {'utilization': 62, 'resets_at': '2030-10-02T15:00:00Z'},
                                    'seven_day': {'utilization': 87, 'resets_at': '2030-10-05T09:00:00Z'}})),
            ("groq", ProviderStats(detail="Testdaten für die visuelle Prüfung.",
               metrics=[("Modelle im Abruf", "12"), ("Limits", "Nicht veröffentlicht")], authenticated=True)),
        ):
            manager.events.put((pid, "refresh", stats))
        app.drain_events()
        app.update()
        assert set(store.visible()) == {"openrouter", "claude", "groq"}

        updated = app.last_updated
        measured_at = app.stats['claude'].checked_at
        manager.events.put(('claude', 'refresh', ProviderStats('paused', 'Browser geschlossen', detail='Abruf pausiert.')))
        app.drain_events()
        assert store.data['providers']['claude']['connected'], 'A closed browser must retain the saved login'
        assert app.stats['claude'].value == '13%' and app.stats['claude'].status == 'paused'
        assert app.stats['claude'].stale
        assert app.stats['claude'].checked_at == measured_at and app.last_updated == updated, 'Paused quota values must not become fresh readings'

        app.toggle_provider("claude", False)
        assert "claude" not in store.visible()
        manager.refresh_calls.clear()
        app.refresh_all()
        assert set(manager.refresh_calls) == {"openrouter", "groq"}, "Disabled providers must not refresh"
        app.toggle_provider("claude", True)
        manager.events.put(("claude", "refresh", ProviderStats("error", "Offline")))
        app.drain_events()
        assert store.data["providers"]["claude"]["connected"], "Network errors must not delete a login"
        manager.events.put(("claude", "refresh", ProviderStats("unauthorized", "Abgelaufen")))
        app.drain_events()
        assert "claude" not in store.visible(), "Expired logins must be hidden"

        for mode in ("Light", "Dark", "System"):
            app.set_theme(mode)
            for tab in ("Anbieter", "Darstellung", "Allgemein"):
                app.page = "settings"
                app.change_settings_tab(tab)
                app.update()
            app.navigate("overview")
            app.update()
        app.set_interval("Manuell")
        assert app.refresh_job is None
        app.set_interval("1 Minute")
        assert app.refresh_job is not None
        app.open_key_dialog("mistral_api")
        app.update()
        # Repeated login checks must preserve the actual controls and the key being typed.
        app.connections_page()
        assert 'chatgpt' in app.connection_rows, 'Codex must have its own connection and toggle in settings'
        app.connect('chatgpt')
        assert manager.codex_connections == 1 and 'chatgpt' not in app.waiting
        assert 'antigravity' in app.connection_rows
        app.connect('antigravity')
        assert manager.antigravity_connections == 1 and 'antigravity' not in app.waiting
        app.waiting["chatgpt"] = time.monotonic() + 60
        app.refresh_widgets()
        app.update()
        app.main_scroll._parent_canvas.yview_moveto(.45)
        app.update()
        scroll = app.main_scroll
        position = scroll._parent_canvas.yview()[0]
        controls = {pid: (row, dict(row.buttons)) for pid, row in app.connection_rows.items()}
        entry = app.key_dialog.entry
        entry.insert(0, "fixture-being-typed")
        focus = app.focus_get()
        with patch.object(app, "render", wraps=app.render) as renders, patch.object(store, "save", wraps=store.save) as saves:
            for i in range(30):
                manager.events.put(("chatgpt", "poll", ProviderStats("pending", "Noch offen", detail="Anmeldung läuft")))
                manager.events.put(("openrouter", "refresh", ProviderStats(value=f"${i}", authenticated=True)))
                app.drain_events()
                app.update()
            assert renders.call_count == 0, "Polling must not rebuild settings"
            assert saves.call_count == 0, "Polling must not repeatedly write settings"
        assert app.main_scroll is scroll
        assert abs(scroll._parent_canvas.yview()[0] - position) < .01, "Polling must not reset scroll"
        assert all(app.connection_rows[pid] is row and row.buttons == buttons for pid, (row, buttons) in controls.items())
        assert app.key_dialog.entry is entry and entry.get() == "fixture-being-typed"
        assert app.focus_get() == focus, "Polling must preserve keyboard focus"
        assert "chatgpt" in app.waiting and not store.data["providers"]["chatgpt"]["connected"]
        manager.events.put(('chatgpt', 'poll', ProviderStats(authenticated=True, detail='Sitzung bestätigt.')))
        app.drain_events()
        assert store.data['providers']['chatgpt']['connected'] and 'chatgpt' not in app.waiting
        assert 'chatgpt' in store.visible(), 'A detected browser login must appear in both overviews'
        app.waiting['chatgpt'] = time.monotonic() + 60
        manager.events.put(("chatgpt", "poll", ProviderStats("closed", "Geschlossen")))
        app.drain_events()
        assert "chatgpt" not in app.waiting, "Closed login windows must stop polling"
        app.key_dialog.close()
        app.update()
        for pid in ("openai_usage", "anthropic_usage"):
            app.open_key_dialog(pid)
            app.update()
            assert app.key_dialog.entry.cget("placeholder_text") == "Admin-API-Schlüssel"
            app.key_dialog.close()
        app.show_compact()
        def settle():
            deadline = time.monotonic() + .25
            while time.monotonic() < deadline:
                app.update()
                time.sleep(.01)

        settle()
        assert app.state() == "withdrawn"
        assert app.compact.state() == "normal"
        app.set_topmost(True)
        app.update()
        assert app.compact.attributes("-topmost") == 1
        app.set_topmost(False)
        app.update()
        assert app.compact.attributes("-topmost") == 0
        compact_rows = dict(app.compact.provider_rows)
        app.compact.geometry("+140+160")
        app.update()
        geometry = app.compact.geometry()
        app.refresh_widgets()
        with patch.object(app.compact, "geometry", wraps=app.compact.geometry) as sizes, patch.object(app.compact, "attributes", wraps=app.compact.attributes) as attributes:
            for i in range(30):
                manager.events.put(("openrouter", "refresh", ProviderStats(value=f"${i}", authenticated=True)))
                app.drain_events()
                app.update()
            assert sizes.call_count == 0, "Usage checks must not resize or reposition the widget"
            assert attributes.call_count == 0, "Usage checks must not reapply topmost"
        assert app.compact.provider_rows == compact_rows
        assert app.compact.geometry() == geometry
        app.refresh_all()
        app.update()
        assert app.compact.refresh_button.cget("state") == "disabled"
        for pid in store.visible():
            manager.events.put((pid, "refresh", ProviderStats(authenticated=True)))
        app.drain_events()
        assert app.compact.refresh_button.cget("state") == "normal", "Refresh must become available again"
        # This script pumps update() instead of mainloop(). Dispose of destroyed Tk
        # test widgets on their owner thread before starting the native tray worker.
        import gc
        gc.collect()
        app.start_tray()
        assert app.tray.ready.wait(5), "Notification-area icon did not start"
        assert app.tray.icon.visible, "Notification-area icon is not visible"
        app.hide_to_tray()
        app.update()
        assert app.state() == "withdrawn" and app.compact.state() == "withdrawn"
        # Run a tray callback on a worker, then verify Tk receives and handles its queue event.
        import threading
        thread = threading.Thread(target=lambda: app.manager.events.put(("__app__", "compact", None)))
        thread.start()
        thread.join()
        app.drain_events()
        app.update()
        assert app.compact.state() == "normal" and app.state() == "withdrawn"
        app.expand()
        app.update()
        assert app.compact.state() == "withdrawn" and app.state() == "normal"
        assert not callback_errors, callback_errors

        # Restore a dashboard fixture for manual inspection, explicitly marked as test data.
        app.set_theme("Dark")
        app.stats["openrouter"] = ProviderStats(value="$18.42", label="Verfügbares Schlüssellimit",
             detail="Das Budget dieses Schlüssels; das Kontoguthaben kann davon abweichen.", progress=.26,
             metrics=[("Verbrauch gesamt", "$6.5800"), ("Heute", "$0.3200")], authenticated=True)
        app.stats["groq"] = ProviderStats(label="Kein Tokenzähler verfügbar",
             detail="Schlüssel geprüft. Nutzung im Anbieter-Dashboard öffnen.",
             metrics=[("Tokenverbrauch", "Nicht abrufbar"), ("Tracking", "Anbieter-Dashboard")], authenticated=True)
        store.data["providers"]["claude"]["connected"] = True
        app.stats['claude'] = claude_usage({'five_hour': {'utilization': 62, 'resets_at': '2030-10-02T15:00:00Z'},
                                          'seven_day': {'utilization': 87, 'resets_at': '2030-10-05T09:00:00Z'}})
        store.data['providers']['chatgpt']['connected'] = True
        app.stats['chatgpt'] = codex_usage({'rateLimits': {'primary': {'usedPercent': 0, 'windowDurationMins': 300, 'resetsAt': 1900000000},
                                                        'secondary': {'usedPercent': 100, 'windowDurationMins': 10080, 'resetsAt': 1900500000}}})
        store.data['providers']['gemini_chat']['connected'] = True
        app.stats['gemini_chat'] = page_usage('Aktuelle Nutzung\n0% genutzt\nWöchentliches Limit\n6% genutzt', 'gemini_chat')
        app.stats['gemini_chat'].windows[0].resets_at = '2030-10-02T12:56:00+00:00'
        app.stats['gemini_chat'].windows[1].resets_at = '2030-10-07T07:56:00+00:00'
        store.data['providers']['antigravity']['connected'] = True
        app.stats['antigravity'] = antigravity_usage(quotas())
        app.refreshing.clear()
        app.banner_text = "UI-Testdaten · keine echten Konten oder Schlüssel verbunden."
        app.navigate("overview")
        app.set_filter('Abos & Apps')
        assert set(app.provider_cards) == {'claude', 'chatgpt', 'gemini_chat', 'antigravity'}, 'The subscription filter must include local app limits'
        app.set_filter('API')
        assert set(app.provider_cards) == {'openrouter', 'groq'}, 'Subscription limits must not appear as API usage'
        app.set_filter('Alle')
        app.title("TokenTracker · UI-Prüfung mit Testdaten")
        app.update()
        app.show_compact()
        app.update()
        meters = app.compact.provider_rows['chatgpt'].quota
        google_meters = app.compact.provider_rows['gemini_chat'].quota
        assert google_meters.rows['five_hour'][0].cget('text') == '100% übrig'
        assert google_meters.rows['seven_day'][0].cget('text') == '94% übrig'
        assert meters.rows['five_hour'][0].cget('text') == '100% übrig'
        assert meters.rows['seven_day'][0].cget('text') == '0% übrig'
        assert meters.rows['five_hour'][1].get() == 1 and meters.rows['seven_day'][1].get() == 0
        ag_meters = app.compact.provider_rows['antigravity'].quota
        assert [ag_meters.rows[key][0].cget('text') for key in ag_meters.rows] == ['76% übrig', '33% übrig', '12% übrig', '90% übrig']
        for _ in range(5):
            manager.events.put(('antigravity', 'refresh', antigravity_usage(quotas())))
            app.drain_events()
        assert app.compact.provider_rows['antigravity'].quota is ag_meters
        manager.events.put(('antigravity', 'refresh', ProviderStats('paused', detail='Antigravity ist geschlossen.')))
        app.drain_events()
        assert store.data['providers']['antigravity']['connected'] and app.stats['antigravity'].stale
        assert len(app.stats['antigravity'].windows) == 4
        assert 'Stand' in app.compact.provider_rows['antigravity'].caption.cget('text')
        manager.events.put(('antigravity', 'refresh', antigravity_usage(quotas())))
        app.drain_events()
        manager.events.put(('chatgpt', 'refresh', ProviderStats('error', detail='Test: vorübergehender Abruffehler.')))
        app.drain_events()
        assert app.stats['chatgpt'].stale and app.stats['chatgpt'].windows[1].remaining_percent == 0
        assert app.compact.provider_rows['chatgpt'].quota is meters, 'Quota updates must preserve controls'
        assert 'Stand' in app.compact.provider_rows['chatgpt'].caption.cget('text')
        app.expand()
        app.update()
        assert app.provider_cards['gemini_chat'].quota.rows['seven_day'][0].cget('text') == '94% übrig'
        assert app.provider_cards['antigravity'].quota.rows['claude_gpt_five_hour'][0].cget('text') == '12% übrig'
        pools = app.provider_cards['antigravity'].quota.group_frames
        assert pools['Gemini'].grid_info()['column'] == 0 and pools['Claude / GPT'].grid_info()['column'] == 1
        print("UI smoke: passed (60 repeated updates, stable controls/focus/input/scroll/window, login cancellation, refresh, themes, compact/expanded, topmost, tray)", flush=True)
        if "--capture" in sys.argv:
            from PIL import ImageGrab
            destination = Path(__file__).resolve().parents[1] / "test-output"
            destination.mkdir(exist_ok=True)

            def capture(name):
                app.update()
                app.after(400, lambda: None)
                time.sleep(.5)
                app.update()
                # Capture only the window created by this test, never the user's desktop.
                for attempt in range(3):
                    try:
                        ImageGrab.grab(window=int(app.wm_frame(), 0)).save(destination / name)
                        break
                    except OSError:
                        if attempt == 2:
                            raise
                        time.sleep(.3)
                        app.update()

            capture("dashboard-dark.png")
            app.connections_page()
            capture("settings-dark.png")
            app.change_settings_tab("Darstellung")
            capture("appearance-dark.png")
            app.set_theme("Light")
            capture("appearance-light.png")
            app.navigate("overview")
            capture("dashboard-light.png")
            app.show_compact()
            app.update()
            ImageGrab.grab(window=int(app.compact.wm_frame(), 0)).save(destination / "compact-light.png")
            app.set_theme("Dark")
            app.set_topmost(True)
            app.update()
            time.sleep(.5)
            app.update()
            ImageGrab.grab(window=int(app.compact.wm_frame(), 0)).save(destination / "compact-dark.png")
            app.compact.rows._parent_canvas.yview_moveto(1)
            app.update()
            time.sleep(.3)
            ImageGrab.grab(window=int(app.compact.wm_frame(), 0)).save(destination / 'compact-gemini-dark.png')
            for pid in store.visible():
                if pid != 'antigravity':
                    store.data['providers'][pid]['enabled'] = False
            app.compact.render()
            app.compact.rows._parent_canvas.yview_moveto(0)
            app.update()
            time.sleep(.3)
            ImageGrab.grab(window=int(app.compact.wm_frame(), 0)).save(destination / 'compact-antigravity-dark.png')
            app.expand()
            capture('dashboard-antigravity-dark.png')
            app.set_theme('Light')
            app.show_compact()
            app.update()
            time.sleep(.3)
            ImageGrab.grab(window=int(app.compact.wm_frame(), 0)).save(destination / 'compact-antigravity-light.png')
            print("Window previews saved to test-output", flush=True)
        if "--preview" in sys.argv:
            app.mainloop()
        else:
            app.close()


if __name__ == "__main__":
    run()
