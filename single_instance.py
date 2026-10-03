"""A second launch reveals the existing compact window instead of duplicating profiles."""
import ctypes
from ctypes import wintypes
import hashlib
import os
from pathlib import Path


class InstanceGuard:
    def __init__(self, identity=None):
        self.acquired = True
        self.mutex = None
        self.event = None
        if os.name != "nt":
            return
        identity = identity or str(Path(__file__).resolve().parent).lower()
        name = "Local\\SYPTokenTracker-" + hashlib.sha256(identity.encode()).hexdigest()[:24]
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        self.kernel.CreateMutexW.restype = wintypes.HANDLE
        self.kernel.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        self.kernel.CreateEventW.restype = wintypes.HANDLE
        self.kernel.SetEvent.argtypes = [wintypes.HANDLE]
        self.kernel.SetEvent.restype = wintypes.BOOL
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL
        self.mutex = self.kernel.CreateMutexW(None, False, name)
        if not self.mutex:
            raise RuntimeError("TokenTracker konnte die Instanz-Sperre nicht erstellen.")
        self.acquired = ctypes.get_last_error() != 183
        self.event = self.kernel.CreateEventW(None, False, False, name + "-show")
        if not self.event:
            self.close()
            raise RuntimeError("TokenTracker konnte das Fenster-Signal nicht erstellen.")
        if not self.acquired:
            self.kernel.SetEvent(self.event)

    def requested(self):
        return bool(self.event and self.kernel.WaitForSingleObject(self.event, 0) == 0)

    def close(self):
        if self.event:
            self.kernel.CloseHandle(self.event)
            self.event = None
        if self.mutex:
            self.kernel.CloseHandle(self.mutex)
            self.mutex = None
