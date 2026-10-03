"""Stable independent meters for subscription windows in either overview."""
import customtkinter as ctk

from api_clients import UsageWindow
from subscription_usage import remaining_label, reset_label, window_specs
from ui_style import *


class QuotaMeters(ctk.CTkFrame):
    def __init__(self, parent, compact=False, provider_id=None):
        super().__init__(parent, fg_color='transparent')
        self.compact = compact
        self.rows = {}
        self.specs = window_specs(provider_id)
        self.group_frames = {}
        previous_group = None
        for key, title, group in self.specs:
            parent = self
            if group and not compact:
                if group not in self.group_frames:
                    column = len(self.group_frames)
                    self.grid_columnconfigure(column, weight=1, uniform='model-pools')
                    frame = ctk.CTkFrame(self, fg_color='transparent')
                    frame.grid(row=0, column=column, sticky='nsew', padx=(0, 6) if column == 0 else (6, 0))
                    self.group_frames[group] = frame
                parent = self.group_frames[group]
            if group and group != previous_group:
                label(parent, group, 10 if compact else 12, ACCENT, True,
                      height=18 if compact else 23).pack(anchor='w', pady=(3 if previous_group else 0, 5))
                previous_group = group
            row = ctk.CTkFrame(parent, fg_color='transparent')
            row.pack(fill='x', pady=(0, 7 if compact else 12))
            row.grid_columnconfigure(0, weight=1)
            name = label(row, title, 10 if compact else 12, MUTED, True, height=18 if compact else 26)
            name.grid(row=0, column=0, sticky='w')
            value = label(row, 'Nicht gemeldet', 11 if compact else 14, MUTED, True, height=18 if compact else 26)
            value.grid(row=0, column=1, sticky='e')
            progress = ctk.CTkProgressBar(row, height=3 if compact else 5, fg_color=BORDER)
            progress.grid(row=1, column=0, columnspan=2, sticky='ew', pady=(4, 3))
            reset = label(row, '', 9 if compact else 10, MUTED, height=15 if compact else 20)
            reset.grid(row=2, column=0, columnspan=2, sticky='w')
            self.rows[key] = (value, progress, reset, None)

    def update_stats(self, stats):
        windows = {window.key: window for window in stats.windows}
        for key, title, group in self.specs:
            window = windows.get(key, UsageWindow(key, title, group=group))
            remaining = window.remaining_percent
            color = MUTED if stats.stale or remaining is None else RED if remaining == 0 else AMBER if remaining <= 10 else GREEN
            value, progress, reset, previous = self.rows[key]
            changed(value, text=remaining_label(window), text_color=color)
            changed(progress, progress_color=color)
            amount = remaining / 100 if remaining is not None else 0
            if previous != amount:
                progress.set(amount)
                self.rows[key] = (value, progress, reset, amount)
            changed(reset, text='Im aktuellen Tarif deaktiviert' if window.disabled else
                    reset_label(window) if remaining is not None else 'Wert vom Anbieter noch nicht gelesen')
