"""Shared appearance primitives for persistent desktop widgets."""
import customtkinter as ctk

BG = ("#F4F5F9", "#101219")
SIDE = ("#FFFFFF", "#151821")
SURFACE = ("#FFFFFF", "#1B1F2B")
INSET = ("#F1F2F7", "#151923")
BORDER = ("#E3E6EF", "#2A3040")
TEXT = ("#202538", "#EFF1F8")
MUTED = ("#6D758A", "#969FB6")
ACCENT = ("#6954D9", "#9C8BF8")
ACCENT_BG = ("#EEEAFD", "#2C2546")
GREEN = ("#198568", "#54CFAB")
AMBER = ("#A46D14", "#E8BA65")
RED = ("#B54555", "#F18896")


def label(parent, text, size=13, color=TEXT, bold=False, **kwargs):
    return ctk.CTkLabel(parent, text=text, text_color=color,
                        font=ctk.CTkFont(family="Segoe UI", size=size, weight="bold" if bold else "normal"), **kwargs)


def button(parent, text, command, primary=False, **kwargs):
    return ctk.CTkButton(parent, text=text, command=command, height=kwargs.pop("height", 38), corner_radius=9,
                         font=ctk.CTkFont(family="Segoe UI", size=13, weight="bold"),
                         fg_color=ACCENT if primary else INSET,
                         hover_color=("#5B47C5", "#8774E3") if primary else BORDER,
                         text_color="white" if primary else TEXT, **kwargs)


def panel(parent, **kwargs):
    return ctk.CTkFrame(parent, fg_color=SURFACE, corner_radius=14, border_width=1, border_color=BORDER, **kwargs)


def changed(widget, **properties):
    cache = getattr(widget, "_tracker_properties", {})
    updates = {name: value for name, value in properties.items() if name not in cache or cache[name] != value}
    if updates:
        widget.configure(**updates)
        cache.update(updates)
        widget._tracker_properties = cache


def status_color(stats):
    return GREEN if stats.status == "ok" else MUTED if stats.status == "paused" else AMBER if stats.status in ("pending", "warning", "unverified") else RED
