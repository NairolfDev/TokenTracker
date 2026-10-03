"""Stable widgets: polling updates values without destroying controls or moving windows."""
import customtkinter as ctk
from datetime import datetime

from api_clients import ProviderStats
from providers import PROVIDERS, tracking_support
from ui_style import *
from quota_widgets import QuotaMeters
from subscription_usage import empty_quota


class ConnectionRow(ctk.CTkFrame):
    def __init__(self, parent, app, pid):
        super().__init__(parent, fg_color=SURFACE, corner_radius=14, border_width=1, border_color=BORDER)
        self.app, self.pid = app, pid
        provider = PROVIDERS[pid]
        self.grid_columnconfigure(1, weight=1)
        label(self, provider.monogram, 16, provider.color, True, width=43, height=43, fg_color=INSET,
              corner_radius=12).grid(row=0, column=0, rowspan=2, padx=(17, 12), pady=(18, 12))
        title = ctk.CTkFrame(self, fg_color="transparent")
        title.grid(row=0, column=1, sticky="w", pady=(15, 0))
        label(title, provider.name, 15, bold=True).pack(side="left")
        self.status = label(title, "", 11, MUTED)
        self.status.pack(side="left", padx=4)
        label(self, tracking_support(pid), 10, MUTED, wraplength=320, justify="left").grid(row=1, column=1, sticky="w", pady=(0, 10))
        self.enabled = ctk.BooleanVar(value=app.store.data["providers"][pid]["enabled"])
        self.toggle = ctk.CTkSwitch(self, text="", variable=self.enabled, width=73, switch_width=35,
                         switch_height=19, text_color=MUTED, progress_color=ACCENT, font=ctk.CTkFont(size=11),
                         command=lambda: app.toggle_provider(pid, self.enabled.get()))
        self.toggle.grid(row=0, column=3, rowspan=2, padx=(10, 18))
        self.actions = ctk.CTkFrame(self, fg_color="transparent")
        self.actions.grid(row=0, column=2, rowspan=2, padx=8)
        self.buttons = {
            "connect": button(self.actions, "Im Browser verbinden" if provider.kind == "oauth" else
                            "Codex verbinden" if provider.kind == 'codex' else
                            "Verbinden" if provider.kind == 'antigravity' else
                            "Anmelden" if provider.kind == "browser" else "API verbinden",
                            lambda: app.connect(pid), primary=provider.kind == "oauth", width=172 if provider.kind == "oauth" else 126),
            "verify": button(self.actions, "Prüfen", lambda: app.verify(pid), width=75),
            "disconnect": button(self.actions, "Trennen", lambda: app.disconnect(pid), width=83),
            "cancel": button(self.actions, "Abbrechen", lambda: app.cancel_login(pid), width=93),
        }
        self.action_mode = None
        self.helper = ctk.CTkFrame(self, fg_color="transparent")
        if provider.kind == "oauth":
            label(self.helper, "Freigabe im Browser. Bestehender Schlüssel optional.", 10, MUTED).pack(side="left")
            button(self.helper, "Schlüssel verwenden", lambda: app.open_key_dialog(pid), width=150, height=27).pack(side="right")
        elif provider.kind == "browser":
            button(self.helper, "Anbieter-Fenster öffnen  ↗", lambda: app.open_provider(pid), width=195, height=27).pack(side="left")
        elif provider.kind == 'codex':
            label(self.helper, 'Nutzt dein angemeldetes Codex-Konto. Der ChatGPT-Browser kann geschlossen bleiben.', 10, MUTED,
                  wraplength=580, justify='left').pack(side='left')
        elif provider.kind == 'antigravity':
            label(self.helper, 'Nutzt deine Anmeldung in der laufenden Antigravity-App.', 10, MUTED,
                  wraplength=370, justify='left').pack(side='left')
            button(self.helper, 'Antigravity öffnen  ↗', lambda: app.open_provider(pid), width=162, height=27).pack(side='right', padx=(10, 0))
        self.message = label(self, "", 11, MUTED, wraplength=690, justify="left", anchor="w")
        self.message.grid(row=3, column=1, columnspan=3, sticky="ew", padx=(0, 18), pady=(0, 13))
        self.update_state()

    def update_state(self):
        app, pid = self.app, self.pid
        state, waiting, busy = app.store.data["providers"][pid], pid in app.waiting, app.manager.busy(pid)
        text = "Anmeldung läuft" if waiting else "Wird geprüft" if busy else "Verbunden" if state["connected"] else "Nicht verbunden"
        changed(self.status, text="  ·  " + text, text_color=AMBER if waiting or busy else GREEN if state["connected"] else MUTED)
        if self.enabled.get() != state["enabled"]:
            self.enabled.set(state["enabled"])
        changed(self.toggle, text="Ein" if state["enabled"] else "Aus")
        mode = ("verify", "cancel") if waiting else ("verify", "disconnect") if state["connected"] else ("connect",)
        if self.action_mode != mode:
            for widget in self.buttons.values():
                widget.pack_forget()
            for name in mode:
                self.buttons[name].pack(side="left", padx=3)
            self.action_mode = mode
        changed(self.buttons["connect"], state="disabled" if busy else "normal")
        provider = PROVIDERS[pid]
        if provider.kind in ('browser', 'codex', 'antigravity') or (provider.kind == "oauth" and not state["connected"] and not waiting):
            if not self.helper.winfo_manager():
                self.helper.grid(row=2, column=1, columnspan=3, sticky="ew", pady=(0, 12), padx=(0, 16))
        else:
            self.helper.grid_remove()
        message = app.provider_messages.get(pid, "")
        changed(self.message, text=message, text_color=AMBER if waiting else MUTED)
        if message:
            self.message.grid()
        else:
            self.message.grid_remove()


class ProviderCard(ctk.CTkFrame):
    def __init__(self, parent, app, pid):
        super().__init__(parent, fg_color=SURFACE, corner_radius=14, border_width=1, border_color=BORDER)
        self.app, self.pid = app, pid
        provider = PROVIDERS[pid]
        header = ctk.CTkFrame(self, fg_color="transparent")
        header.pack(fill="x", padx=20, pady=(20, 17))
        label(header, provider.monogram, 16, provider.color, True, width=42, height=42, fg_color=INSET, corner_radius=12).pack(side="left")
        naming = ctk.CTkFrame(header, fg_color="transparent")
        naming.pack(side="left", padx=10)
        label(naming, provider.name, 16, bold=True).pack(anchor="w")
        label(naming, "Modell-Limits" if pid == 'antigravity' else "Abo-Limits" if pid in ('claude', 'chatgpt', 'gemini_chat') else "Browser-Sitzung" if provider.kind == "browser" else "API-Verbindung", 11, MUTED).pack(anchor="w")
        self.dot = label(header, "●", 16, MUTED)
        self.dot.pack(side="right")
        self.caption = label(self, "", 9, MUTED, True)
        self.caption.pack(anchor="w", padx=22)
        self.value = label(self, "", 22, bold=True)
        self.value.pack(anchor="w", padx=22, pady=(4, 2))
        self.progress = ctk.CTkProgressBar(self, height=5, fg_color=BORDER, progress_color=GREEN)
        self.progress.pack(fill="x", padx=22, pady=(12, 10))
        self.progress_value = None
        self.detail = label(self, "", 11, MUTED, justify="left", anchor="nw", wraplength=325, height=55)
        self.detail.pack(fill="x", padx=22, pady=(0, 10))
        self.quota = QuotaMeters(self, provider_id=pid)
        self.quota.pack(fill='x', padx=22, pady=(5, 0))
        metrics = ctk.CTkFrame(self, fg_color=INSET, corner_radius=9)
        metrics.pack(fill="x", padx=20, pady=(0, 15))
        self.metrics_frame = metrics
        self.metrics = []
        for _ in range(2):
            line = ctk.CTkFrame(metrics, fg_color="transparent")
            line.pack(fill="x", padx=12, pady=5)
            title, value = label(line, "", 10, MUTED), label(line, "", 10, bold=True)
            title.pack(side="left")
            value.pack(side="right")
            self.metrics.append((title, value))
        bottom = ctk.CTkFrame(self, fg_color="transparent")
        bottom.pack(fill="x", padx=20, pady=(0, 17))
        button(bottom, "Antigravity öffnen  ↗" if pid == 'antigravity' else "Beim Anbieter öffnen  ↗", lambda: app.open_provider(pid), width=178, height=32).pack(side="left")
        self.checked = label(bottom, "", 10, MUTED)
        self.checked.pack(side="right")
        self.update_state()

    def update_state(self):
        stats = self.app.stats.get(self.pid, ProviderStats("pending", "Wird geprüft …", detail="Gespeicherter Zugang wird geprüft."))
        if self.pid in ('claude', 'chatgpt', 'gemini_chat', 'antigravity') and not stats.windows:
            stats = empty_quota(PROVIDERS[self.pid].name, stats.detail, stats.status, stats.authenticated, self.pid)
        color = status_color(stats)
        changed(self.dot, text_color=color)
        changed(self.caption, text=stats.label.upper())
        changed(self.value, text=stats.value)
        changed(self.detail, text=stats.detail)
        changed(self.progress, progress_color=color)
        if stats.progress is None or stats.windows:
            self.progress.pack_forget()
        elif not self.progress.winfo_manager():
            self.progress.pack(fill="x", padx=22, pady=(12, 10), before=self.detail)
        progress = stats.progress if stats.progress is not None else 0
        if self.progress_value != progress:
            self.progress.set(progress)
            self.progress_value = progress
        rows = stats.metrics[:2] or [("Tracking", "Kein Zähler verfügbar")]
        if stats.windows:
            if not self.quota.winfo_manager():
                self.quota.pack(fill='x', padx=22, pady=(5, 0), before=self.metrics_frame if self.metrics_frame.winfo_manager() else self.checked.master)
            self.quota.update_stats(stats)
            self.metrics_frame.pack_forget()
        else:
            self.quota.pack_forget()
            if not self.metrics_frame.winfo_manager():
                self.metrics_frame.pack(fill='x', padx=20, pady=(0, 15), before=self.checked.master)
        for i, (title, value) in enumerate(self.metrics):
            pair = rows[i] if i < len(rows) else ("", "")
            changed(title, text=pair[0])
            changed(value, text=pair[1])
        checked = 'Letzter Stand ' + datetime.fromisoformat(stats.checked_at).astimezone().strftime('%H:%M') if stats.stale else 'Geprüft' if stats.authenticated else 'Hinweis'
        changed(self.checked, text=checked, text_color=color)


class CompactRow(ctk.CTkFrame):
    def __init__(self, parent, app, pid):
        super().__init__(parent, fg_color=SURFACE, corner_radius=14, border_width=1, border_color=BORDER)
        self.app, self.pid = app, pid
        provider = PROVIDERS[pid]
        self.grid_columnconfigure(1, weight=1)
        label(self, provider.monogram, 11, provider.color, True, width=29, height=29, fg_color=INSET,
              corner_radius=8).grid(row=0, column=0, rowspan=2, padx=(10, 8), pady=10)
        label(self, provider.name, 12, bold=True).grid(row=0, column=1, sticky="w", pady=(7, 0))
        self.value = label(self, "", 13, GREEN, True)
        self.value.grid(row=0, column=2, sticky="e", padx=(4, 11), pady=(7, 0))
        self.caption = label(self, "", 9, MUTED)
        self.caption.grid(row=1, column=1, columnspan=2, sticky="w", pady=(0, 8))
        self.progress = ctk.CTkProgressBar(self, height=3, progress_color=GREEN, fg_color=BORDER)
        self.progress.grid(row=2, column=0, columnspan=3, sticky="ew", padx=11, pady=(0, 8))
        self.progress_value = None
        self.quota = QuotaMeters(self, compact=True, provider_id=pid)
        self.quota.grid(row=3, column=0, columnspan=3, sticky='ew', padx=12, pady=(3, 3))
        self.update_state()

    def update_state(self):
        stats = self.app.stats.get(self.pid, ProviderStats("pending", "Wird geprüft …"))
        if self.pid in ('claude', 'chatgpt', 'gemini_chat', 'antigravity') and not stats.windows:
            stats = empty_quota(PROVIDERS[self.pid].name, stats.detail, stats.status, stats.authenticated, self.pid)
        value = stats.value if len(stats.value) <= 21 else stats.value[:19] + "…"
        changed(self.value, text=value, text_color=status_color(stats))
        caption = stats.label if stats.label != "Kontostatus" else "Kein Nutzungszähler verfügbar"
        if self.pid == 'gemini' and stats.authenticated:
            changed(self.value, text='API-Zugang')
            caption = 'Google-Abo-Limits: Gemini verbinden'
        stamp = datetime.fromisoformat(stats.checked_at).astimezone().strftime('%H:%M')
        changed(self.caption, text='Stand ' + stamp + ' · ' + caption if stats.stale else caption)
        if stats.windows:
            self.quota.grid()
            self.quota.update_stats(stats)
        else:
            self.quota.grid_remove()
        if stats.progress is None or stats.windows:
            self.progress.grid_remove()
        else:
            self.progress.grid()
            changed(self.progress, progress_color=status_color(stats))
            if self.progress_value != stats.progress:
                self.progress.set(stats.progress)
                self.progress_value = stats.progress
