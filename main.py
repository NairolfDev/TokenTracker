"""TokenTracker desktop UI. All UI state is owned by Tk's main thread."""
from datetime import datetime
from dataclasses import replace
from pathlib import Path
import queue
import time
import webbrowser

import customtkinter as ctk
from ui_style import *
from provider_widgets import CompactRow, ConnectionRow, ProviderCard

from api_clients import ProviderStats
from manager import ConnectionManager
from providers import CATALOG, PROVIDERS
from storage import SettingsStore, StorageError
from antigravity_usage import open_antigravity

def clear(parent):
    for child in parent.winfo_children():
        child.destroy()


class KeyDialog(ctk.CTkToplevel):
    def __init__(self, app, provider_id):
        super().__init__(app)
        self.app = app
        self.provider_id = provider_id
        provider = PROVIDERS[provider_id]
        self.title(f"{provider.name} verbinden")
        self.geometry("510x440" if provider.credential_hint else "490x350")
        self.resizable(False, False)
        self.configure(fg_color=BG)
        self.transient(app)
        self.protocol("WM_DELETE_WINDOW", self.close)
        label(self, provider.name + " verbinden", 23, bold=True).pack(anchor="w", padx=28, pady=(26, 8))
        label(self, "Dein Schlüssel wird zuerst geprüft und anschließend\nverschlüsselt auf diesem Windows-Konto gespeichert.",
              color=MUTED, justify="left").pack(anchor="w", padx=28, pady=(0, 18))
        if provider.credential_hint:
            label(self, provider.credential_hint, 11, AMBER, justify="left", wraplength=455).pack(anchor="w", padx=28, pady=(0, 9))
            button(self, "Zugang beim Anbieter öffnen  ↗", lambda: webbrowser.open(provider.url),
                   height=28, width=225).pack(anchor="w", padx=28, pady=(0, 13))
        self.entry = ctk.CTkEntry(self, placeholder_text="Admin-API-Schlüssel" if provider.credential_hint else "API-Schlüssel", show="•", height=42,
                                fg_color=SURFACE, border_color=BORDER, text_color=TEXT)
        self.entry.pack(fill="x", padx=28)
        self.show_key = ctk.BooleanVar(value=False)
        ctk.CTkCheckBox(self, text="Schlüssel anzeigen", variable=self.show_key, text_color=MUTED,
                       checkbox_width=17, checkbox_height=17, font=ctk.CTkFont(size=12),
                       command=lambda: self.entry.configure(show="" if self.show_key.get() else "•")).pack(anchor="w", padx=28, pady=12)
        self.message = label(self, "", color=RED, wraplength=430, justify="left")
        self.message.pack(anchor="w", padx=28)
        self.connect_button = button(self, "Prüfen & verbinden", self.connect, primary=True)
        self.connect_button.pack(side="right", padx=28, pady=(8, 24))
        button(self, "Abbrechen", self.close, width=105).pack(side="left", padx=28, pady=(8, 24))
        self.bind("<Return>", lambda _: self.connect())
        self.bind("<Escape>", lambda _: self.close())
        self.after(150, self.entry.focus_set)
        self.grab_set()

    def connect(self):
        key = self.entry.get().strip()
        if not key or any(char.isspace() for char in key):
            self.message.configure(text="Bitte einen Schlüssel ohne Leerzeichen eingeben.")
            return
        if self.app.manager.connect_key(self.provider_id, key):
            self.connect_button.configure(state="disabled", text="Zugang wird geprüft …")
            self.message.configure(text="", text_color=RED)
            self.entry.configure(state="disabled")
            self.app.provider_messages[self.provider_id] = "Zugang wird geprüft …"

    def result(self, result):
        if result.authenticated:
            self.close()
        else:
            self.connect_button.configure(state="normal", text="Erneut prüfen")
            self.entry.configure(state="normal")
            self.message.configure(text=result.detail)

    def close(self):
        if self.app.manager.busy(self.provider_id):
            self.app.manager.cancel_login(self.provider_id)
        self.app.key_dialog = None
        self.grab_release()
        self.destroy()


class CompactWindow(ctk.CTkToplevel):
    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title("TokenTracker · Kurzübersicht")
        self.configure(fg_color=BG)
        self.resizable(False, False)
        self.protocol("WM_DELETE_WINDOW", app.hide_to_tray)
        self.bind("<Escape>", lambda _: app.hide_to_tray())
        self.withdraw()
        self.header = ctk.CTkFrame(self, fg_color="transparent")
        self.header.pack(fill="x", padx=17, pady=(17, 12))
        label(self.header, "T", 17, "white", True, width=33, height=33, fg_color=ACCENT, corner_radius=9).pack(side="left")
        title = ctk.CTkFrame(self.header, fg_color="transparent")
        title.pack(side="left", padx=9)
        label(title, "TokenTracker", 14, bold=True).pack(anchor="w")
        self.pin_label = label(title, "KURZÜBERSICHT", 9, MUTED)
        self.pin_label.pack(anchor="w")
        button(self.header, "↗", app.expand, width=34, height=31).pack(side="right")
        button(self.header, "—", app.hide_to_tray, width=31, height=31).pack(side="right", padx=4)
        self.rows = ctk.CTkScrollableFrame(self, fg_color="transparent", corner_radius=0,
                                          scrollbar_button_color=BORDER, scrollbar_button_hover_color=MUTED)
        self.rows.grid_columnconfigure(0, weight=1)
        bottom = ctk.CTkFrame(self, fg_color="transparent")
        bottom.pack(side="bottom", fill="x", padx=17, pady=(10, 14))
        self.time_label = label(bottom, "", 10, MUTED)
        self.time_label.pack(side="left")
        self.refresh_button = button(bottom, "↻", app.refresh_all, width=32, height=29)
        self.refresh_button.pack(side="right")
        button(bottom, "Ausklappen", app.expand, width=102, height=29).pack(side="right", padx=5)
        self.rows.pack(fill="both", expand=True, padx=11)
        self.placed = False
        self.provider_rows = {}
        self.visible_ids = None
        self.topmost_value = None
        self.render()

    def render(self):
        topmost = self.app.store.data["always_on_top"]
        if self.topmost_value != topmost:
            self.attributes("-topmost", topmost)
            self.topmost_value = topmost
        changed(self.pin_label, text="●  IM VORDERGRUND" if topmost else "KURZÜBERSICHT",
                text_color=ACCENT if topmost else MUTED)
        visible = tuple(self.app.store.visible())
        if self.visible_ids != visible:
            clear(self.rows)
            self.provider_rows = {}
            for row, pid in enumerate(visible):
                widget = CompactRow(self.rows, self.app, pid)
                widget.grid(row=row, column=0, sticky="ew", pady=(0, 7))
                self.provider_rows[pid] = widget
            if not visible:
                label(self.rows, "Dein erster Anbieter wartet.", 15, bold=True).grid(row=0, column=0, pady=(17, 5))
                label(self.rows, "Anmelden in den Einstellungen,\ndann erscheint hier deine Übersicht.", 11, MUTED,
                      justify="center").grid(row=1, column=0, pady=(0, 12))
                button(self.rows, "+  Anbieter verbinden", lambda: self.app.expand("settings"), primary=True,
                       width=185, height=32).grid(row=2, column=0, pady=(0, 14))
            available = max(270, int((self.winfo_screenheight() - 120) / self._get_window_scaling()))
            height = min(590, available, 160 + sum(330 if pid == 'antigravity' else 170 if pid in ('claude', 'chatgpt', 'gemini_chat') else 84 for pid in visible)) if visible else 270
            self.geometry(f"360x{height}")
            self.rows.configure(height=max(90, height-120))
            self.visible_ids = visible
        for widget in self.provider_rows.values():
            widget.update_state()
        if not self.placed:
            position = self.app.store.data.get("compact_position")
            if position:
                x, y = position
                if not (0 <= x < self.winfo_screenwidth()-100 and 0 <= y < self.winfo_screenheight()-100):
                    position = None
            if not position:
                x, y = max(20, self.winfo_screenwidth()-580), 70
            self.geometry(f"+{x}+{y}")
            self.placed = True
        updated = self.app.last_updated
        changed(self.time_label, text=f"Stand {updated:%H:%M}" if updated else "Noch kein Abruf")
        changed(self.refresh_button, state="disabled" if self.app.refreshing else "normal")


class TokenTrackerApp(ctk.CTk):
    def __init__(self, store=None, manager=None, auto_start=True):
        self.store = store or SettingsStore()
        ctk.set_appearance_mode(self.store.data["theme"])
        super().__init__()
        self.manager = manager or ConnectionManager(vault=self.store.vault)
        self.title("TokenTracker · Dein KI-Cockpit")
        self.geometry("1180x820")
        self.minsize(980, 680)
        self.configure(fg_color=BG)
        self.attributes("-topmost", self.store.data["always_on_top"])
        self.protocol("WM_DELETE_WINDOW", self.show_compact)
        self.page = "overview"
        self.settings_tab = "Anbieter"
        self.filter = "Alle"
        self.stats = self.store.usage_cache.load()
        self.provider_messages = {}
        self.waiting = {}
        self.refreshing = set()
        times = [datetime.fromisoformat(s.checked_at) for s in self.stats.values()]
        self.last_updated = max(times) if times else None
        self.refresh_job = None
        self.key_dialog = None
        self.compact = None
        self.tray = None
        self.tray_available = False
        self.view_mode = "expanded"
        self.instance = None
        self.main_scroll = None
        self.rendered_page = None
        self.provider_cards = {}
        self.connection_rows = {}
        self.summary_values = []
        self.overview_visible = ()
        self.closing = False
        self.banner_text = self.store.warning
        self.banner_error = bool(self.store.warning)
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(0, weight=1)
        self._sidebar()
        self.content = ctk.CTkFrame(self, fg_color="transparent", corner_radius=0)
        self.content.grid(row=0, column=1, sticky="nsew", padx=32, pady=24)
        self.content.grid_columnconfigure(0, weight=1)
        self.content.grid_rowconfigure(2, weight=1)
        self.render()
        self.bind("<Control-r>", lambda _: self.refresh_all())
        self.bind("<Control-comma>", lambda _: self.navigate("settings"))
        self.after(100, self.drain_events)
        self.after(3500, self.poll_logins)
        self.schedule_refresh()
        if auto_start:
            self.withdraw()
            self.after(100, self.start_tray)
            self.after(180, self.show_compact)
            self.after(700, self.initial_check)

    def _sidebar(self):
        self.sidebar = ctk.CTkFrame(self, width=220, corner_radius=0, fg_color=SIDE)
        self.sidebar.grid(row=0, column=0, sticky="ns")
        self.sidebar.grid_propagate(False)
        self.sidebar.grid_columnconfigure(0, weight=1)
        self.sidebar.grid_rowconfigure(6, weight=1)
        brand = ctk.CTkFrame(self.sidebar, fg_color="transparent")
        brand.grid(row=0, column=0, padx=22, pady=(30, 38), sticky="ew")
        label(brand, "T", 23, "white", True, width=40, height=40, fg_color=ACCENT, corner_radius=11).pack(side="left")
        branding = ctk.CTkFrame(brand, fg_color="transparent")
        branding.pack(side="left", padx=10)
        label(branding, "TokenTracker", 16, bold=True).pack(anchor="w")
        label(branding, "DEIN KI-COCKPIT", 9, color=MUTED).pack(anchor="w")
        label(self.sidebar, "WORKSPACE", 10, MUTED, True).grid(row=1, column=0, sticky="w", padx=26, pady=(0, 12))
        self.nav = {}
        for row, (pid, text) in enumerate((("overview", "◫   Übersicht"), ("settings", "⚙   Einstellungen")), 2):
            self.nav[pid] = button(self.sidebar, text, lambda p=pid: self.navigate(p), anchor="w", width=180)
            self.nav[pid].grid(row=row, column=0, sticky="ew", padx=16, pady=4)
        note = ctk.CTkFrame(self.sidebar, fg_color=INSET, corner_radius=12)
        note.grid(row=7, column=0, padx=16, pady=(12, 20), sticky="ew")
        label(note, "Alles an einem Ort.", 13, bold=True).pack(anchor="w", padx=14, pady=(14, 5))
        label(note, "Deine Anbieter. Deine Zugänge.\nDein Überblick.", 11, MUTED, justify="left").pack(anchor="w", padx=14, pady=(0, 14))
        self.sidebar_count = label(self.sidebar, "", 11, MUTED)
        self.sidebar_count.grid(row=8, column=0, sticky="w", padx=23, pady=(0, 12))
        self.theme_switch = ctk.CTkSegmentedButton(self.sidebar, values=["Hell", "Dunkel"],
                              command=self.quick_theme, height=31, selected_color=ACCENT, selected_hover_color=ACCENT,
                              unselected_color=INSET, unselected_hover_color=BORDER, fg_color=BORDER,
                              font=ctk.CTkFont(size=11))
        self.theme_switch.grid(row=9, column=0, padx=20, pady=(0, 16), sticky="ew")
        self.theme_switch.set("Hell" if ctk.get_appearance_mode() == "Light" else "Dunkel")
        label(self.sidebar, "LOCAL WORKSPACE  /  V2.5", 9, MUTED).grid(row=10, column=0, padx=20, pady=(0, 22), sticky="w")
        button(self.sidebar, "↙  Kurzübersicht", self.show_compact, width=180, height=33).grid(row=5, column=0,
                            sticky="ew", padx=16, pady=(22, 0))

    def navigate(self, page):
        self.page = page
        self.render()

    def connections_page(self):
        self.settings_tab = "Anbieter"
        self.navigate("settings")

    def render(self):
        page_key = (self.page, self.settings_tab if self.page == "settings" else self.filter)
        scroll_position = 0.0
        if self.rendered_page == page_key and self.main_scroll and self.main_scroll.winfo_exists():
            scroll_position = self.main_scroll._parent_canvas.yview()[0]
        self.rendered_page = page_key
        self.provider_cards = {}
        self.connection_rows = {}
        self.summary_values = []
        for pid, nav in self.nav.items():
            nav.configure(fg_color=ACCENT_BG if self.page == pid else "transparent",
                          text_color=ACCENT if self.page == pid else MUTED)
        self.sidebar_count.configure(text=f"●  {len(self.store.visible())} Anbieter im Überblick")
        clear(self.content)
        header = ctk.CTkFrame(self.content, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", pady=(0, 22))
        words = ctk.CTkFrame(header, fg_color="transparent")
        words.pack(side="left")
        label(words, "DEIN WORKSPACE" if self.page == "overview" else "DEIN SETUP", 10, ACCENT, True).pack(anchor="w")
        label(words, "Alles im Blick." if self.page == "overview" else "Einstellungen", 30, bold=True).pack(anchor="w", pady=(3, 4))
        label(words, "Deine KI-Zugänge, Guthaben und Limits." if self.page == "overview" else
              "Verbinde deine Anbieter und mach diesen Ort zu deinem.", 13, MUTED).pack(anchor="w")
        if self.page == "overview":
            self.refresh_button = button(header, "Aktualisieren", self.refresh_all, width=127)
            self.refresh_button.pack(side="right", padx=(8, 0))
            self.refresh_button.configure(state="disabled" if self.refreshing else "normal",
                                          text="Wird aktualisiert …" if self.refreshing else "Aktualisieren")
            button(header, "+  Anbieter", self.connections_page, primary=True, width=118).pack(side="right")
        self.banner = label(self.content, self.banner_text, color=RED if self.banner_error else GREEN,
                            anchor="w", wraplength=840, justify="left")
        self.banner.grid(row=1, column=0, sticky="ew", pady=(0, 8) if self.banner_text else 0)
        if not self.banner_text:
            self.banner.grid_remove()
        self.body = ctk.CTkFrame(self.content, fg_color="transparent")
        self.body.grid(row=2, column=0, sticky="nsew")
        self.body.grid_columnconfigure(0, weight=1)
        self.body.grid_rowconfigure(0, weight=1)
        if self.page == "overview":
            self.render_overview()
        else:
            self.render_settings()
        self.footer = label(self.content, self.footer_text(), 11, MUTED, anchor="w")
        self.footer.grid(row=3, column=0, sticky="ew", pady=(13, 0))
        if self.compact and self.compact.winfo_exists():
            self.compact.render()
        if scroll_position:
            current_scroll = self.main_scroll

            def restore_scroll():
                if not self.closing and current_scroll.winfo_exists():
                    current_scroll._parent_canvas.yview_moveto(scroll_position)
            self.after_idle(restore_scroll)

    def footer_text(self):
        interval = self.store.data["refresh_minutes"]
        updated = "Noch kein Abruf" if not self.last_updated else f"Letzter Abruf {self.last_updated:%H:%M:%S}"
        return f"{updated}    ·    {'Automatisch alle ' + str(interval) + ' Min.' if interval else 'Manuelle Aktualisierung'}    ·    Lokal auf deinem Gerät"

    def flash(self, text, error=False):
        self.banner_text, self.banner_error = text, error
        if hasattr(self, "banner") and self.banner.winfo_exists():
            self.banner.configure(text=text, text_color=RED if error else GREEN)
            self.banner.grid(pady=(0, 8))

    def save(self):
        try:
            self.store.save()
            return True
        except (OSError, StorageError):
            self.flash("Die Einstellungen konnten nicht gespeichert werden. Schreibzugriff auf den Projektordner prüfen.", True)
            return False

    def report_callback_exception(self, exception_type, exception_value, traceback_object):
        """pythonw has no console; preserve a useful stack without logging user inputs."""
        import traceback
        log = Path(__file__).resolve().parent / ".tracker" / "ui-error.log"
        try:
            log.parent.mkdir(parents=True, exist_ok=True)
            with log.open("a", encoding="utf-8") as output:
                output.write(f"{datetime.now().astimezone().isoformat()} {exception_type.__name__}\n")
                output.writelines(traceback.format_tb(traceback_object))
        except OSError:
            pass
        if not self.closing:
            self.flash("Ein Oberflächenfehler ist aufgetreten. Details stehen in .tracker/ui-error.log.", True)

    def render_overview(self):
        scroll = ctk.CTkScrollableFrame(self.body, fg_color="transparent", corner_radius=0,
                                       scrollbar_button_color=BORDER, scrollbar_button_hover_color=MUTED)
        scroll.grid(row=0, column=0, sticky="nsew")
        self.main_scroll = scroll
        scroll.grid_columnconfigure(0, weight=1)
        visible = self.store.visible()
        summaries = ctk.CTkFrame(scroll, fg_color="transparent")
        summaries.grid(row=0, column=0, sticky="ew", pady=(0, 25))
        for col in range(3):
            summaries.grid_columnconfigure(col, weight=1, uniform="summary")
        warnings = sum(self.stats.get(pid, ProviderStats()).status in ("warning", "error", "unverified") for pid in visible)
        for col, (title, value, caption, color) in enumerate((
            ("IM ÜBERBLICK", f"{len(visible):02d}", "aktive Verbindungen", ACCENT),
            ("BRAUCHT AUFMERKSAMKEIT", f"{warnings:02d}", "Hinweise deiner Anbieter", AMBER if warnings else GREEN),
            ("AKTUALISIERUNG", f"{self.store.data['refresh_minutes']} Min." if self.store.data["refresh_minutes"] else "Manuell",
             "Du bestimmst den Rhythmus", TEXT),
        )):
            card = panel(summaries)
            card.grid(row=0, column=col, sticky="nsew", padx=(0 if col == 0 else 7, 0 if col == 2 else 7))
            label(card, title, 9, MUTED, True).pack(anchor="w", padx=18, pady=(16, 7))
            summary_value = label(card, value, 28, color, True)
            summary_value.pack(anchor="w", padx=18)
            self.summary_values.append(summary_value)
            label(card, caption, 11, MUTED).pack(anchor="w", padx=18, pady=(4, 16))
        titlebar = ctk.CTkFrame(scroll, fg_color="transparent")
        titlebar.grid(row=1, column=0, sticky="ew", pady=(0, 15))
        label(titlebar, "Deine Anbieter", 18, bold=True).pack(side="left")
        if visible:
            filters = ctk.CTkSegmentedButton(titlebar, values=["Alle", "Abos & Apps", "API"], command=self.set_filter,
                           fg_color=BORDER, unselected_color=INSET, unselected_hover_color=BORDER,
                           selected_color=ACCENT, selected_hover_color=ACCENT, font=ctk.CTkFont(size=12))
            filters.set(self.filter)
            filters.pack(side="right")
        filtered = [pid for pid in visible if self.filter == "Alle" or
                    (PROVIDERS[pid].kind in ('browser', 'codex', 'antigravity')) == (self.filter == 'Abos & Apps')]
        self.overview_visible = tuple(filtered)
        if not visible:
            self.empty_state(scroll)
        elif not filtered:
            empty = panel(scroll)
            empty.grid(row=2, column=0, sticky="ew")
            label(empty, "Noch keine Verbindung in dieser Kategorie.", 15, MUTED).pack(padx=25, pady=40)
        else:
            cards = ctk.CTkFrame(scroll, fg_color="transparent")
            cards.grid(row=2, column=0, sticky="ew")
            for col in range(2):
                cards.grid_columnconfigure(col, weight=1, uniform="provider")
            for index, pid in enumerate(filtered):
                self.provider_card(cards, pid, index // 2, index % 2)
        note = ctk.CTkFrame(scroll, fg_color="transparent")
        note.grid(row=3, column=0, sticky="ew", pady=(20, 8))
        label(note, "Ein ehrlicher Überblick", 12, bold=True).pack(anchor="w")
        label(note, "Manche Anbieter veröffentlichen keine Restlimits. Dann siehst du den Verbindungsstatus\n"
              "und kannst deine Nutzung direkt beim Anbieter öffnen.", 11, MUTED, justify="left").pack(anchor="w", pady=(3, 0))

    def empty_state(self, scroll):
        empty = panel(scroll)
        empty.grid(row=2, column=0, sticky="ew")
        label(empty, "✦", 44, ACCENT, width=78, height=78, fg_color=ACCENT_BG, corner_radius=22).pack(pady=(34, 17))
        label(empty, "Dein Cockpit wartet auf dich.", 24, bold=True).pack()
        label(empty, "Verbinde deinen ersten KI-Anbieter in den Einstellungen.\n"
              "Hier erscheinen nur angemeldete, eingeschaltete Anbieter.", 13, MUTED, justify="center").pack(pady=(9, 22))
        button(empty, "+  Ersten Anbieter verbinden", self.connections_page, primary=True, width=225).pack(pady=(0, 17))
        label(empty, f"{len(CATALOG)} Anbieter  ·  Einzelne Zugänge  ·  Jederzeit umschaltbar", 11, MUTED).pack(pady=(0, 33))

    def provider_card(self, parent, pid, row, col):
        card = ProviderCard(parent, self, pid)
        card.grid(row=row, column=col, sticky="nsew", padx=(0 if col == 0 else 8, 8 if col == 0 else 0), pady=(0, 16))
        self.provider_cards[pid] = card

    def refresh_widgets(self):
        """Background events never recreate settings, dialogs, or existing provider controls."""
        visible = self.store.visible()
        filtered = tuple(pid for pid in visible if self.filter == "Alle" or
                         (PROVIDERS[pid].kind in ('browser', 'codex', 'antigravity')) == (self.filter == 'Abos & Apps'))
        if self.page == "overview" and filtered != self.overview_visible:
            self.render()  # A provider was explicitly connected, disconnected, enabled or disabled.
            return
        for widget in self.connection_rows.values():
            widget.update_state()
        for widget in self.provider_cards.values():
            widget.update_state()
        warnings = sum(self.stats.get(pid, ProviderStats()).status in ("warning", "error", "unverified") for pid in visible)
        if self.summary_values:
            changed(self.summary_values[0], text=f"{len(visible):02d}")
            changed(self.summary_values[1], text=f"{warnings:02d}", text_color=AMBER if warnings else GREEN)
        changed(self.sidebar_count, text=f"●  {len(visible)} Anbieter im Überblick")
        changed(self.footer, text=self.footer_text())
        if self.page == "overview":
            changed(self.refresh_button, state="disabled" if self.refreshing else "normal",
                    text="Wird aktualisiert …" if self.refreshing else "Aktualisieren")
        if self.compact and self.compact.winfo_exists():
            self.compact.render()

    def set_filter(self, value):
        self.filter = value
        self.render()

    def render_settings(self):
        self.body.grid_rowconfigure(0, weight=0)
        self.body.grid_rowconfigure(1, weight=1)
        tabs = ctk.CTkSegmentedButton(self.body, values=["Anbieter", "Darstellung", "Allgemein"], command=self.change_settings_tab,
                    height=37, selected_color=ACCENT, selected_hover_color=ACCENT, unselected_color=INSET,
                    unselected_hover_color=BORDER, fg_color=BORDER, font=ctk.CTkFont(size=13))
        tabs.set(self.settings_tab)
        tabs.grid(row=0, column=0, sticky="w", pady=(0, 20))
        scroll = ctk.CTkScrollableFrame(self.body, fg_color="transparent", corner_radius=0,
                                       scrollbar_button_color=BORDER, scrollbar_button_hover_color=MUTED)
        scroll.grid(row=1, column=0, sticky="nsew")
        self.main_scroll = scroll
        scroll.grid_columnconfigure(0, weight=1)
        if self.settings_tab == "Anbieter":
            self.render_connections(scroll)
        elif self.settings_tab == "Darstellung":
            self.render_appearance(scroll)
        else:
            self.render_general(scroll)

    def change_settings_tab(self, value):
        self.settings_tab = value
        self.render()

    def render_connections(self, scroll):
        introduction = ctk.CTkFrame(scroll, fg_color=ACCENT_BG, corner_radius=12)
        introduction.grid(row=0, column=0, sticky="ew", pady=(0, 20))
        label(introduction, "Deine Verbindungen, einzeln steuerbar.", 14, bold=True).pack(anchor="w", padx=18, pady=(14, 4))
        label(introduction, "Anmelden, prüfen und einschalten. Ausschalten blendet einen Anbieter aus und pausiert seine Abrufe.",
              11, MUTED, wraplength=750, justify="left").pack(anchor="w", padx=18, pady=(0, 14))
        row = 1
        for heading, subtitle, subset in (
            ("Abonnements & Apps", "Browser-Zugänge einzeln anmelden. Codex und Antigravity nutzen die Anmeldung in ihrer App.",
             [p for p in CATALOG if p.kind in ("browser", "oauth", "codex", "antigravity")]),
            ("Entwickler-APIs", "API-Zugänge sind eigene Konten und unabhängig von deinem Chat-Abonnement.",
             [p for p in CATALOG if p.kind == "api"]),
        ):
            title = ctk.CTkFrame(scroll, fg_color="transparent")
            title.grid(row=row, column=0, sticky="ew", pady=(8, 12))
            label(title, heading, 17, bold=True).pack(anchor="w")
            label(title, subtitle, 11, MUTED).pack(anchor="w", pady=(3, 0))
            row += 1
            for provider in subset:
                self.connection_row(scroll, provider, row)
                row += 1

    def connection_row(self, parent, provider, row):
        widget = ConnectionRow(parent, self, provider.id)
        widget.grid(row=row, column=0, sticky="ew", pady=(0, 10))
        self.connection_rows[provider.id] = widget

    def render_appearance(self, scroll):
        card = panel(scroll)
        card.grid(row=0, column=0, sticky="ew")
        label(card, "Ein Look, der zu dir passt.", 20, bold=True).pack(anchor="w", padx=25, pady=(23, 7))
        label(card, "Wähle dein Farbschema. Änderungen werden sofort gespeichert.", 12, MUTED).pack(anchor="w", padx=25)
        previews = ctk.CTkFrame(card, fg_color="transparent")
        previews.pack(fill="x", padx=20, pady=24)
        for col, (mode, title, background, surface, color) in enumerate((
            ("Light", "Hell", "#F4F5F9", "#FFFFFF", "#202538"),
            ("Dark", "Dunkel", "#101219", "#1B1F2B", "#EFF1F8"),
            ("System", "System", "#272937", "#373B4D", "#EFF1F8"),
        )):
            previews.grid_columnconfigure(col, weight=1, uniform="themes")
            choice = ctk.CTkFrame(previews, fg_color=background, border_width=2,
                                  border_color=ACCENT if self.store.data["theme"] == mode else BORDER, corner_radius=12)
            choice.grid(row=0, column=col, sticky="nsew", padx=6)
            mock = ctk.CTkFrame(choice, fg_color=surface, height=80, corner_radius=8)
            mock.pack(fill="x", padx=14, pady=(17, 10))
            label(mock, "TokenTracker", 13, color, True).pack(anchor="w", padx=10, pady=(8, 7))
            progress = ctk.CTkProgressBar(mock, height=5, width=130, fg_color=background, progress_color="#9C8BF8")
            progress.pack(padx=10, pady=(0, 14))
            progress.set(0.65)
            button(choice, ("✓  " if self.store.data["theme"] == mode else "") + title,
                   lambda m=mode: self.set_theme(m), width=120).pack(fill="x", padx=14, pady=(0, 15))
        label(card, "System folgt dem Windows-Farbschema.", 11, MUTED).pack(anchor="w", padx=25, pady=(0, 22))
        top = panel(scroll)
        top.grid(row=1, column=0, sticky="ew", pady=16)
        label(top, "Immer im Vordergrund", 15, bold=True).pack(anchor="w", padx=25, pady=(20, 4))
        label(top, "Behalte deinen Überblick über anderen Fenstern.", 12, MUTED).pack(anchor="w", padx=25)
        variable = ctk.BooleanVar(value=self.store.data["always_on_top"])
        ctk.CTkSwitch(top, text="Aktiv", variable=variable, progress_color=ACCENT, text_color=TEXT,
                     command=lambda: self.set_topmost(variable.get())).pack(anchor="w", padx=25, pady=(15, 22))

    def render_general(self, scroll):
        card = panel(scroll)
        card.grid(row=0, column=0, sticky="ew")
        label(card, "Aktualisierung", 19, bold=True).pack(anchor="w", padx=25, pady=(23, 7))
        label(card, "Nur eingeschaltete, verbundene Anbieter werden automatisch abgerufen.", 12, MUTED).pack(anchor="w", padx=25)
        interval = self.store.data["refresh_minutes"]
        selected = ("1 Minute" if interval == 1 else str(interval) + " Minuten") if interval else "Manuell"
        ctk.CTkOptionMenu(card, values=["Manuell", "1 Minute", "5 Minuten", "10 Minuten", "15 Minuten", "30 Minuten", "60 Minuten"],
                     variable=ctk.StringVar(value=selected), command=self.set_interval, height=39, width=205,
                     fg_color=INSET, button_color=BORDER, button_hover_color=ACCENT, text_color=TEXT,
                     dropdown_fg_color=SURFACE, dropdown_text_color=TEXT).pack(anchor="w", padx=25, pady=(18, 23))
        data = panel(scroll)
        data.grid(row=1, column=0, sticky="ew", pady=16)
        label(data, "Deine Daten bleiben bei dir.", 19, bold=True).pack(anchor="w", padx=25, pady=(23, 7))
        for title, description in (
            ("Verschlüsselte Schlüssel", "API-Schlüssel sind an dein Windows-Konto gebunden und stehen nicht in den Einstellungen."),
            ("Getrennte Sitzungen", "Jeder Browser-Anbieter hat ein eigenes lokales Profil. Deine normale Browser-Sitzung bleibt eigenständig."),
            ("Einzeln trennbar", "»Trennen« entfernt den lokalen Zugang. API-Schlüssel kannst du zusätzlich beim Anbieter widerrufen."),
        ):
            label(data, title, 13, bold=True).pack(anchor="w", padx=25, pady=(13, 4))
            label(data, description, 11, MUTED, wraplength=710, justify="left").pack(anchor="w", padx=25)
        label(data, "TOKEN TRACKER  /  VERSION 2.5", 10, ACCENT, True).pack(anchor="w", padx=25, pady=(25, 22))

    def quick_theme(self, value):
        self.set_theme("Light" if value == "Hell" else "Dark")

    def set_theme(self, mode):
        self.store.data["theme"] = mode
        ctk.set_appearance_mode(mode)
        self.theme_switch.set("Hell" if ctk.get_appearance_mode() == "Light" else "Dunkel")
        self.save()
        self.render()
        self.after(80, self.sync_window_mode)

    def set_topmost(self, value):
        self.store.data["always_on_top"] = value
        self.attributes("-topmost", value)
        if self.compact and self.compact.winfo_exists():
            self.compact.render()
        if self.tray:
            self.tray.update_topmost(value)
        self.save()

    def set_interval(self, value):
        self.store.data["refresh_minutes"] = 0 if value == "Manuell" else int(value.split()[0])
        self.save()
        self.schedule_refresh()
        self.flash("Aktualisierungsrhythmus gespeichert.")
        changed(self.footer, text=self.footer_text())

    def toggle_provider(self, pid, value):
        self.store.data["providers"][pid]["enabled"] = value
        if not value:
            self.cancel_login(pid)
        self.save()
        self.refresh_widgets()
        if value and self.store.data["providers"][pid]["connected"]:
            self.verify(pid)

    def connect(self, pid):
        kind = PROVIDERS[pid].kind
        if kind == "api":
            self.open_key_dialog(pid)
            return
        if kind == 'codex':
            if self.manager.connect_codex():
                self.provider_messages[pid] = 'Deine offizielle Codex-Anmeldung und beide Abo-Zeitfenster werden geprüft …'
                self.refresh_widgets()
            return
        if kind == 'antigravity':
            if self.manager.connect_antigravity():
                self.provider_messages[pid] = 'Deine Antigravity-Anmeldung und die Limits beider Modellgruppen werden geprüft …'
                self.refresh_widgets()
            return
        started = self.manager.connect_openrouter() if kind == "oauth" else self.manager.connect_browser(pid)
        if started:
            self.waiting[pid] = time.monotonic() + 300
            self.provider_messages[pid] = "Im geöffneten Anbieter-Fenster anmelden; die App erkennt die Verbindung automatisch, auch in einem weiteren Tab."
            if pid == "claude":
                self.provider_messages[pid] += " Einen E-Mail-Login-Link ebenfalls in diesem Fenster öffnen."
            self.refresh_widgets()

    def open_key_dialog(self, pid):
        if self.key_dialog and self.key_dialog.winfo_exists():
            self.key_dialog.focus()
            return
        if self.manager.busy(pid):
            self.flash("Für diesen Anbieter läuft bereits ein Vorgang.")
            return
        self.key_dialog = KeyDialog(self, pid)

    def cancel_login(self, pid):
        self.manager.cancel_login(pid)
        self.waiting.pop(pid, None)
        self.refreshing.discard(pid)
        self.provider_messages[pid] = "Anmeldung abgebrochen. Du kannst sie jederzeit neu starten."
        self.refresh_widgets()

    def verify(self, pid):
        started = self.manager.refresh(pid, login_poll=pid in self.waiting, manual=True)
        if started:
            self.provider_messages[pid] = "Verbindung wird geprüft …"
            self.refresh_widgets()

    def disconnect(self, pid):
        if self.manager.disconnect(pid):
            self.provider_messages[pid] = "Lokale Verbindung wird entfernt …"
            self.refresh_widgets()
        else:
            self.flash("Der Anbieter wird gerade geprüft. Bitte kurz warten.")

    def open_provider(self, pid):
        if PROVIDERS[pid].kind == 'antigravity':
            if not open_antigravity():
                self.flash('Antigravity konnte nicht gefunden werden. Die installierte App manuell öffnen.', True)
        elif PROVIDERS[pid].kind == "browser":
            self.connect(pid)
        elif not webbrowser.open(PROVIDERS[pid].url):
            self.flash("Der Browser konnte nicht geöffnet werden.", True)

    def initial_check(self):
        for pid, state in self.store.data["providers"].items():
            if state['enabled'] and PROVIDERS[pid].kind in ('codex', 'antigravity'):
                if state['connected'] and self.manager.refresh(pid):
                    self.refreshing.add(pid)
                continue
            if state["enabled"] and PROVIDERS[pid].kind != "browser":
                try:
                    if self.store.vault.get(pid) and self.manager.refresh(pid):
                        self.refreshing.add(pid)
                except StorageError as error:
                    state["connected"] = False
                    self.provider_messages[pid] = str(error)
                    self.flash(str(error), True)
        self.refresh_all()

    def refresh_all(self):
        for pid in self.store.visible():
            if self.manager.refresh(pid):
                self.refreshing.add(pid)
        if self.refreshing:
            if self.page == "overview" and hasattr(self, "refresh_button") and self.refresh_button.winfo_exists():
                changed(self.refresh_button, state="disabled", text="Wird aktualisiert …")
            if self.compact and self.compact.winfo_exists():
                changed(self.compact.refresh_button, state="disabled")
        elif not self.store.visible():
            self.flash("Verbinde einen Anbieter in den Einstellungen, um Daten abzurufen.")

    def schedule_refresh(self):
        if self.refresh_job:
            self.after_cancel(self.refresh_job)
            self.refresh_job = None
        interval = self.store.data["refresh_minutes"]
        if interval:
            self.refresh_job = self.after(interval * 60000, self.auto_refresh)

    def auto_refresh(self):
        self.refresh_job = None
        self.refresh_all()
        self.schedule_refresh()

    def poll_logins(self):
        if self.closing:
            return
        for pid, deadline in list(self.waiting.items()):
            if time.monotonic() > deadline:
                self.manager.cancel_login(pid)
                self.waiting.pop(pid, None)
                self.provider_messages[pid] = "Die Anmeldung ist abgelaufen. Bitte erneut starten."
                self.refresh_widgets()
            elif PROVIDERS[pid].kind == "browser":
                self.manager.refresh(pid, login_poll=True)
        self.after(3500, self.poll_logins)

    def drain_events(self):
        if self.closing:
            return
        changed_ui = False
        before = [(s["connected"], s["enabled"]) for s in self.store.data["providers"].values()]
        while True:
            try:
                pid, operation, result = self.manager.events.get_nowait()
            except queue.Empty:
                break
            if operation == "oauth_wait":
                continue
            if pid == "__app__":
                self.tray_action(operation)
                if self.closing:
                    return
                continue
            self.refreshing.discard(pid)
            changed_ui = True
            if operation == "cancelled":
                continue
            state = self.store.data["providers"][pid]
            self.provider_messages[pid] = result.detail
            if operation == "disconnect" and result.status == "disconnected":
                state["connected"] = False
                self.stats.pop(pid, None)
                try:
                    self.store.usage_cache.delete(pid)
                except OSError:
                    self.flash('Der letzte Messstand konnte nicht entfernt werden.', True)
                self.waiting.pop(pid, None)
                self.flash(PROVIDERS[pid].name + " wurde getrennt.")
            elif operation == "login":
                if result.status in ("error", "closed"):
                    self.waiting.pop(pid, None)
                    self.flash(result.detail, True)
            elif operation == "poll" and not result.authenticated:
                # Polling is an in-progress login check, not a fresh usage reading or a logout.
                if result.status == "closed":
                    self.waiting.pop(pid, None)
                continue
            elif result.status == "paused":
                previous = self.stats.get(pid)
                self.stats[pid] = replace(previous, status="paused", detail=result.detail, authenticated=False, stale=True) if previous else result
                # Keep the timestamp of the last real reading. A closed browser is
                # neither fresh quota data nor proof that the saved login expired.
                continue
            else:
                previous = self.stats.get(pid)
                measured = any(w.used_percent is not None for w in result.windows)
                if previous and previous.windows and not measured and result.status != 'unauthorized':
                    self.stats[pid] = replace(previous, status=result.status, detail=result.detail, stale=True,
                                              authenticated=result.authenticated)
                elif operation != "connect" or result.authenticated or not state["connected"]:
                    self.stats[pid] = result
                if result.authenticated and measured:
                    try:
                        self.store.usage_cache.put(pid, result)
                    except OSError:
                        self.flash('Messwerte sind sichtbar, konnten aber nicht gespeichert werden.', True)
                self.last_updated = datetime.now().astimezone()
                if result.authenticated:
                    state["connected"] = True
                    if pid in self.waiting or operation == "connect":
                        self.waiting.pop(pid, None)
                        self.flash(PROVIDERS[pid].name + " erfolgreich verbunden.")
                elif result.status == "unauthorized" and not (operation == "connect" and state["connected"]):
                    state["connected"] = False
                if operation == "connect":
                    self.waiting.pop(pid, None)
                    if self.key_dialog and self.key_dialog.provider_id == pid:
                        self.key_dialog.result(result)
                    if not result.authenticated:
                        self.flash(result.detail, True)
        after = [(s["connected"], s["enabled"]) for s in self.store.data["providers"].values()]
        if before != after:
            self.save()
        if changed_ui:
            self.refresh_widgets()
        self.after(100, self.drain_events)

    def start_tray(self):
        try:
            from tray import TrayController
            self.tray = TrayController(self.manager.events, self.store.data["always_on_top"])
            self.tray.start()
            self.tray_available = True
        except Exception:
            self.tray_available = False
            self.flash("Taskleisten-Symbol nicht verfügbar. Abhängigkeiten über start.bat aktualisieren.", True)

    def tray_action(self, action):
        if action == "compact":
            self.show_compact()
        elif action == "expand":
            self.expand()
        elif action == "settings":
            self.expand("settings")
        elif action == "refresh":
            self.refresh_all()
        elif action == "topmost":
            self.set_topmost(not self.store.data["always_on_top"])
        elif action == "quit":
            self.close()
        elif action == "tray_error":
            self.tray_available = False
            self.show_compact()
            self.flash("Das Taskleisten-Symbol konnte nicht gestartet werden.", True)

    def remember_compact_position(self):
        if self.compact and self.compact.winfo_exists() and self.compact.state() != "withdrawn":
            self.store.data["compact_position"] = [self.compact.winfo_x(), self.compact.winfo_y()]

    def show_compact(self):
        if self.key_dialog and self.key_dialog.winfo_exists():
            self.key_dialog.close()
        if not self.compact or not self.compact.winfo_exists():
            self.compact = CompactWindow(self)
        self.compact.render()
        self.withdraw()
        self.compact.deiconify()
        self.compact.lift()
        self.view_mode = "compact"
        # CustomTkinter reapplies the Windows titlebar asynchronously on new windows.
        self.after(80, self.sync_window_mode)

    def sync_window_mode(self):
        if self.closing:
            return
        if self.view_mode == "compact" and self.compact and self.compact.winfo_exists():
            self.withdraw()
            self.compact.deiconify()
        elif self.view_mode == "tray":
            self.withdraw()
            if self.compact and self.compact.winfo_exists():
                self.compact.withdraw()
        elif self.view_mode == "expanded":
            if self.compact and self.compact.winfo_exists():
                self.compact.withdraw()
            self.deiconify()

    def expand(self, page="overview"):
        self.remember_compact_position()
        if self.compact and self.compact.winfo_exists():
            self.compact.withdraw()
        self.view_mode = "expanded"
        self.navigate(page)
        self.deiconify()
        self.lift()
        self.save()
        self.after(80, self.sync_window_mode)

    def hide_to_tray(self):
        if not self.tray_available:
            self.close()
            return
        self.remember_compact_position()
        if self.compact and self.compact.winfo_exists():
            self.compact.withdraw()
        self.withdraw()
        self.view_mode = "tray"
        self.save()
        self.after(80, self.sync_window_mode)

    def close(self):
        self.remember_compact_position()
        self.closing = True
        self.save()
        if self.tray:
            self.tray.stop()
        self.manager.shutdown()
        if self.instance:
            self.instance.close()
        self.destroy()

    def check_instance_signal(self):
        if self.closing:
            return
        if self.instance and self.instance.requested():
            self.show_compact()
        self.after(500, self.check_instance_signal)


if __name__ == "__main__":
    try:
        from single_instance import InstanceGuard
        guard = InstanceGuard()
        if guard.acquired:
            app = TokenTrackerApp()
            app.instance = guard
            app.after(500, app.check_instance_signal)
            app.mainloop()
        else:
            guard.close()
    except Exception:
        import traceback
        log = Path(__file__).resolve().parent / ".tracker" / "startup-error.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(traceback.format_exc(), encoding="utf-8")
        raise
