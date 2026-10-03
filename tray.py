"""Windows notification-area icon. Callbacks only enqueue work for the Tk thread."""
import threading

from PIL import Image, ImageDraw


def tray_image():
    image = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((3, 3, 61, 61), radius=16, fill="#9C8BF8")
    # Simple vector-like T remains legible at the taskbar's 16px size.
    draw.rounded_rectangle((17, 16, 47, 25), radius=2, fill="white")
    draw.rounded_rectangle((27, 23, 37, 49), radius=2, fill="white")
    return image


class TrayController:
    def __init__(self, events, topmost=False):
        self.events = events
        self.topmost = topmost
        self.icon = None
        self.thread = None
        self.ready = threading.Event()

    def start(self):
        import pystray

        def send(action):
            return lambda *args: self.events.put(("__app__", action, None))

        self.icon = pystray.Icon("SYPTokenTracker", tray_image(), "TokenTracker · KI-Kurzübersicht",
                                menu=pystray.Menu(
                                    pystray.MenuItem("Kurzübersicht öffnen", send("compact"), default=True),
                                    pystray.MenuItem("Großes Dashboard öffnen", send("expand")),
                                    pystray.MenuItem("Einstellungen", send("settings")),
                                    pystray.Menu.SEPARATOR,
                                    pystray.MenuItem("Jetzt aktualisieren", send("refresh")),
                                    pystray.MenuItem("Immer im Vordergrund", send("topmost"), checked=lambda _: self.topmost),
                                    pystray.Menu.SEPARATOR,
                                    pystray.MenuItem("Beenden", send("quit")),
                                ))

        def setup(icon):
            icon.visible = True
            self.ready.set()

        def run():
            try:
                self.icon.run(setup=setup)
            except Exception:
                self.events.put(("__app__", "tray_error", None))

        self.thread = threading.Thread(target=run, name="notification-tray", daemon=True)
        self.thread.start()

    def update_topmost(self, value):
        self.topmost = value
        if self.icon and self.ready.is_set():
            self.icon.update_menu()

    def stop(self):
        if self.icon:
            self.icon.stop()
