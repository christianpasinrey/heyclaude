"""Win32 keyboard injection, window enumeration and process-tree helpers."""
from __future__ import annotations

import ctypes
import logging
import time
from ctypes import wintypes

import win32api
import win32con
import win32gui
import win32process

log = logging.getLogger("voice-input.win32")


# ---------- SendInput ----------

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG)),
    ]


class _INPUTunion(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("padding", ctypes.c_byte * 32)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTunion)]


_user32 = ctypes.windll.user32
_kernel32 = ctypes.windll.kernel32


def _send_key(vk: int, up: bool) -> None:
    # Real scan codes matter — some console hosts drop wScan=0 events.
    scan = _user32.MapVirtualKeyW(vk, 0)
    flags = KEYEVENTF_KEYUP if up else 0
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.u.ki = KEYBDINPUT(vk, scan, flags, 0, None)
    _user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(inp))


def _send_unicode_char(ch: str) -> None:
    code = ord(ch)
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.u.ki = KEYBDINPUT(0, code, KEYEVENTF_UNICODE, 0, None)
    _user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(inp))
    inp2 = INPUT()
    inp2.type = INPUT_KEYBOARD
    inp2.u.ki = KEYBDINPUT(0, code, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, None)
    _user32.SendInput(1, ctypes.byref(inp2), ctypes.sizeof(inp2))


def type_text_and_enter(text: str) -> None:
    """Inject `text` as Unicode keystrokes followed by Enter.

    Bypasses the clipboard (Ctrl+V is not always honored by TUIs) by
    delivering each character as a synthesized WM_CHAR event.
    """
    for ch in text:
        if ch in ("\r", "\n"):
            continue
        _send_unicode_char(ch)
        time.sleep(0.005)
    time.sleep(0.1)
    VK_RETURN = 0x0D
    _send_key(VK_RETURN, False)
    time.sleep(0.02)
    _send_key(VK_RETURN, True)


def send_escape() -> None:
    VK_ESCAPE = 0x1B
    _send_key(VK_ESCAPE, False)
    _send_key(VK_ESCAPE, True)


# ---------- process tree ----------

_TH32CS_SNAPPROCESS = 0x00000002
_PROCESS_QUERY_LIMITED = 0x1000
_STILL_ACTIVE = 259


class _PROCESSENTRY32(ctypes.Structure):
    _fields_ = [
        ('dwSize', wintypes.DWORD),
        ('cntUsage', wintypes.DWORD),
        ('th32ProcessID', wintypes.DWORD),
        ('th32DefaultHeapID', ctypes.c_void_p),
        ('th32ModuleID', wintypes.DWORD),
        ('cntThreads', wintypes.DWORD),
        ('th32ParentProcessID', wintypes.DWORD),
        ('pcPriClassBase', wintypes.LONG),
        ('dwFlags', wintypes.DWORD),
        ('szExeFile', ctypes.c_char * 260),
    ]


def get_parent_pid(pid: int) -> int:
    snap = _kernel32.CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
    if snap == -1 or snap == 0:
        return 0
    try:
        pe = _PROCESSENTRY32()
        pe.dwSize = ctypes.sizeof(pe)
        if not _kernel32.Process32First(snap, ctypes.byref(pe)):
            return 0
        while True:
            if pe.th32ProcessID == pid:
                return int(pe.th32ParentProcessID)
            if not _kernel32.Process32Next(snap, ctypes.byref(pe)):
                break
    finally:
        _kernel32.CloseHandle(snap)
    return 0


def pid_alive(pid: int) -> bool:
    if not pid:
        return False
    try:
        h = _kernel32.OpenProcess(_PROCESS_QUERY_LIMITED, False, pid)
        if not h:
            return False
        try:
            code = wintypes.DWORD()
            if not _kernel32.GetExitCodeProcess(h, ctypes.byref(code)):
                return False
            return code.value == _STILL_ACTIVE
        finally:
            _kernel32.CloseHandle(h)
    except Exception:
        return False


# ---------- window lookup / focus ----------

def _enum_top_window_for_pid(pid: int) -> int | None:
    target: list[int] = []

    def cb(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return True
        _, owner = win32process.GetWindowThreadProcessId(hwnd)
        if owner == pid and win32gui.GetWindowText(hwnd):
            target.append(hwnd)
            return False
        return True

    try:
        win32gui.EnumWindows(cb, None)
    except Exception:
        pass
    return target[0] if target else None


def find_window_for_pid(pid: int) -> int | None:
    """Return a top-level visible HWND owned by ``pid`` or any ancestor.

    Walks up the process tree because terminals (Windows Terminal,
    ConEmu…) own the visible window while the shell child (pwsh, cmd) and
    its child (claude.exe / node.exe) do not.
    """
    if not pid:
        return None
    cur = pid
    chain: list[str] = []
    for _ in range(10):
        hwnd = _enum_top_window_for_pid(cur)
        chain.append(f"{cur}{'→hwnd' if hwnd else ''}")
        if hwnd:
            log.info("find_window pid=%s hwnd=%s chain=%s", pid, hwnd,
                     " ".join(chain))
            return hwnd
        parent = get_parent_pid(cur)
        if not parent or parent == cur:
            log.warning("find_window pid=%s exhausted chain=%s", pid,
                        " ".join(chain))
            return None
        cur = parent
    return None


def force_foreground(hwnd: int) -> bool:
    """Bring ``hwnd`` to the foreground reliably on Windows 10/11.

    SetForegroundWindow lies under foreground-lock — returns success but
    only flashes the taskbar. SwitchToThisWindow (the API Alt-Tab uses)
    bypasses the lock. We prime with an Alt key tap to defuse the lock,
    poll for the actual focus change, and only declare success if the
    foreground really became ``hwnd``.
    """
    if not hwnd:
        return False
    try:
        if win32gui.GetForegroundWindow() == hwnd:
            return True
        placement = win32gui.GetWindowPlacement(hwnd)
        if placement[1] == win32con.SW_SHOWMINIMIZED:
            win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
        # Alt tap unlocks foreground-stealing protection.
        _user32.keybd_event(0x12, 0, 0, 0)
        _user32.keybd_event(0x12, 0, 0x0002, 0)
        try:
            _user32.SwitchToThisWindow(hwnd, True)
        except Exception as e:
            log.warning("SwitchToThisWindow failed: %s", e)
        try:
            win32gui.SetForegroundWindow(hwnd)
        except Exception:
            pass
        for _ in range(20):
            if win32gui.GetForegroundWindow() == hwnd:
                return True
            time.sleep(0.02)
        log.warning("force_foreground hwnd=%s never became fg (fg=%s)",
                    hwnd, win32gui.GetForegroundWindow())
        return False
    except Exception as e:
        log.warning("force_foreground exception: %s", e)
        return False
