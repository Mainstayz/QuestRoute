"""魔兽世界无限服钓鱼助理。

监听默认播放设备上的声音。启动时视为未钓鱼，立刻把游戏切到前台，
用真实按键按下 1，再回到 RETURN_EXE 指定的程序。抛竿 5 秒后才把水花当成咬钩，
按 F 收竿，等 1 到 2 秒再按 1。连续 30 秒没有咬钩水花，就再按一次 1。

    python fish.py
    python fish.py --monitor
    python fish.py --check
    python fish.py --threshold 0.065

Ctrl+C 或 Ctrl+F12 结束。1 键绑抛竿，F 键绑和鱼漂互动。
请关掉音乐，本程序分不清水花和其他短促声。
"""

import argparse
import ctypes
import math
import os
import queue
import random
import sys
import threading
import time
from ctypes import wintypes

try:
    import pyaudiowpatch as pyaudio
except ImportError:
    sys.exit("缺少 pyaudiowpatch。请在本目录执行: python -m pip install -r requirements.txt")

# 超过这么久还没有咬钩，多半是漏听了，重新抛竿。
SILENCE_SEC = 30
# 抛竿之后这么多秒，才开始把水花当成咬钩。
IGNORE_SEC = 5.0
RECAST_MIN = 1.0
RECAST_MAX = 2.0
# 听到咬钩后停一下再按，避免每次都在同一毫秒收竿。
REACT_MIN = 0.3
REACT_MAX = 0.9
CAST_KEY = "1"
LOOT_KEY = "F"
# 按完键回到这个程序。Cursor 是 Cursor.exe，VS Code 是 Code.exe。
RETURN_EXE = "Cursor.exe"
# 按下和回弹的时长每次不同，两段都留在游戏前台。
KEY_DOWN_MIN = 0.08
KEY_DOWN_MAX = 0.18
KEY_UP_MIN = 0.08
KEY_UP_MAX = 0.16
BLOCK_SEC = 0.01
MAX_SPLASH_SEC = 1.5
# 实钓：等待水花最高约 0.056，偏轻的咬钩 0.072，响的咬钩 0.08 以上。
THRESHOLD = 0.065

VK_MENU = 0x12
VK_CONTROL = 0x11
VK_F12 = 0x7B
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_SCANCODE = 0x0008
INPUT_KEYBOARD = 1
SW_RESTORE = 9
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
ULONG_PTR = ctypes.c_size_t

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", INPUT_UNION)]

user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.IsWindow.argtypes = [wintypes.HWND]
user32.IsWindow.restype = wintypes.BOOL
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.restype = ctypes.c_int
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.restype = ctypes.c_int
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetForegroundWindow.restype = wintypes.HWND
user32.IsIconic.argtypes = [wintypes.HWND]
user32.IsIconic.restype = wintypes.BOOL
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.ShowWindow.restype = wintypes.BOOL
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.SetForegroundWindow.restype = wintypes.BOOL
user32.BringWindowToTop.argtypes = [wintypes.HWND]
user32.BringWindowToTop.restype = wintypes.BOOL
user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetAncestor.restype = wintypes.HWND
user32.SwitchToThisWindow.argtypes = [wintypes.HWND, wintypes.BOOL]
user32.SetWindowPos.argtypes = [
    wintypes.HWND,
    wintypes.HWND,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    wintypes.UINT,
]
user32.SetWindowPos.restype = wintypes.BOOL
user32.LockSetForegroundWindow.argtypes = [wintypes.UINT]
user32.LockSetForegroundWindow.restype = wintypes.BOOL
user32.SetFocus.argtypes = [wintypes.HWND]
user32.SetFocus.restype = wintypes.HWND
user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
user32.AttachThreadInput.restype = wintypes.BOOL
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
user32.MapVirtualKeyW.restype = wintypes.UINT
user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT
user32.keybd_event.argtypes = [wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ULONG_PTR]
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_short
kernel32.GetCurrentThreadId.restype = wintypes.DWORD
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL
kernel32.QueryFullProcessImageNameW.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    wintypes.LPWSTR,
    ctypes.POINTER(wintypes.DWORD),
]
kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
kernel32.GetLastError.restype = wintypes.DWORD


class Meter:
    """音量超过阈值的一小段算一声水花，拖得很长的声音不算。"""

    def __init__(self, threshold, max_blocks):
        self.threshold = threshold
        self.max_blocks = max_blocks
        self.blocks = 0
        self.peak = 0.0

    def reset(self):
        self.blocks = 0
        self.peak = 0.0

    def feed(self, rms):
        if rms >= self.threshold:
            self.peak = rms if self.blocks == 0 else max(self.peak, rms)
            self.blocks = min(self.blocks + 1, self.max_blocks + 1)
            return None
        count = self.blocks
        peak = self.peak
        self.blocks = 0
        self.peak = 0.0
        if 1 <= count <= self.max_blocks:
            return peak
        return None


class Session:
    def __init__(self, threshold):
        blocks = max(1, round(MAX_SPLASH_SEC / BLOCK_SEC))
        self.meter = Meter(threshold, blocks)
        self.mode = "arming"  # arming 初始等待 / fishing 等咬钩 / busy 收竿中
        self.last_water = None
        self.last_peak = 0.0
        self.ignore_until = 0.0
        self.retry_at = None

    def update(self, now, rms):
        if self.last_water is None:
            self.last_water = now
        heard = self.meter.feed(rms)
        if heard is not None:
            self.last_peak = heard
            self.last_water = now
            if self.mode == "busy":
                return None
            if self.mode != "fishing":
                return "heard"
            if now < self.ignore_until:
                return "ignore"
            self.mode = "busy"
            return "loot"
        if self.mode == "busy" or self.meter.blocks:
            return None
        if self.retry_at is not None and now >= self.retry_at:
            self.confirm_cast(now)
            return "retry"
        if now - self.last_water >= SILENCE_SEC:
            self.confirm_cast(now)
            return "cast"
        return None

    def confirm_cast(self, now):
        self.mode = "fishing"
        self.ignore_until = now + IGNORE_SEC
        self.last_water = now
        self.retry_at = None
        self.meter.reset()

    def rollback_cast(self, now, delay=5.0):
        self.mode = "arming"
        self.retry_at = now + delay
        self.last_water = now
        self.ignore_until = 0.0
        self.meter.reset()

    def rollback_loot(self, now):
        self.mode = "fishing"
        self.ignore_until = now + IGNORE_SEC
        self.meter.reset()

    def finish_loot(self, now):
        self.confirm_cast(now)


def self_check():
    expect = 40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28
    if ctypes.sizeof(INPUT) != expect:
        raise SystemExit(f"按键结构大小异常: {ctypes.sizeof(INPUT)}，期望 {expect}")
    session = Session(0.02)
    assert session.update(0, 0) is None
    assert session.update(1, 0.4) is None
    assert session.update(1.1, 0) == "heard"
    assert session.mode == "arming"
    assert session.update(1.1 + SILENCE_SEC - 1, 0) is None
    cast_at = 1.1 + SILENCE_SEC
    assert session.update(cast_at, 0) == "cast"
    assert session.mode == "fishing"
    assert session.update(cast_at + 0.5, 0.3) is None
    assert session.update(cast_at + 0.6, 0) == "ignore"
    assert session.update(cast_at + IGNORE_SEC + 1, 0.4) is None
    assert session.update(cast_at + IGNORE_SEC + 1.1, 0) == "loot"
    assert session.mode == "busy"
    assert session.update(cast_at + IGNORE_SEC + 2, 0.4) is None
    assert session.update(cast_at + IGNORE_SEC + 2.1, 0) is None

    session.finish_loot(cast_at + IGNORE_SEC + 3)
    landed = cast_at + IGNORE_SEC + 3.4
    assert session.update(landed, 0.3) is None
    assert session.update(landed + 0.1, 0) == "ignore"
    bite = cast_at + IGNORE_SEC + 8
    assert session.update(bite, 0.5) is None
    assert session.update(bite + 0.1, 0) == "loot"

    session.rollback_cast(200)
    assert session.update(204, 0) is None
    assert session.update(205, 0) == "retry"

    long_sound = Session(0.02)
    long_sound.confirm_cast(0)
    clock = 3.0
    for _ in range(int(MAX_SPLASH_SEC / BLOCK_SEC) + 10):
        assert long_sound.update(clock, 0.9) is None
        clock += BLOCK_SEC
    assert long_sound.update(clock, 0) is None
    assert long_sound.mode == "fishing"


def rms_bytes(data):
    count = len(data) // 2
    if count == 0:
        return 0.0
    samples = memoryview(data).cast("h")
    total = 0
    for sample in samples:
        total += sample * sample
    return math.sqrt(total / count) / 32768.0


def find_loopback(pa):
    try:
        return pa.get_default_wasapi_loopback()
    except Exception as exc:
        raise SystemExit(f"找不到系统声音的回录设备: {exc}") from exc


def open_stream():
    pa = pyaudio.PyAudio()
    try:
        dev = find_loopback(pa)
        rate = int(dev["defaultSampleRate"])
        channels = int(dev["maxInputChannels"])
        if channels < 1 or rate < 1:
            raise SystemExit(f"回录设备不可用: {dev['name']}")
        frames = max(1, int(rate * BLOCK_SEC))
        stream = pa.open(
            format=pyaudio.paInt16,
            channels=channels,
            rate=rate,
            input=True,
            input_device_index=int(dev["index"]),
            frames_per_buffer=frames,
        )
    except BaseException:
        pa.terminate()
        raise
    return pa, stream, frames, dev


def image_path(hwnd):
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
    if not handle:
        return ""
    try:
        size = wintypes.DWORD(1024)
        buf = ctypes.create_unicode_buffer(1024)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return ""
        return buf.value
    finally:
        kernel32.CloseHandle(handle)


def find_wow():
    found = []
    title_buf = ctypes.create_unicode_buffer(512)
    class_buf = ctypes.create_unicode_buffer(256)

    @WNDENUMPROC
    def visit(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        user32.GetWindowTextW(hwnd, title_buf, 512)
        user32.GetClassNameW(hwnd, class_buf, 256)
        title = title_buf.value
        cls = class_buf.value
        interesting = (
            "魔兽世界" in title
            or "World of Warcraft" in title
            or cls == "waApplication Window"
            or cls.startswith("GxWindow")
        )
        if interesting:
            found.append((int(hwnd), title, cls))
        return True

    user32.EnumWindows(visit, 0)
    best = None
    best_score = 0
    for hwnd, title, cls in found:
        exe = image_path(hwnd)
        score = 0
        if os.path.basename(exe).lower() == "wow.exe":
            score += 10
        if cls == "waApplication Window" or cls.startswith("GxWindow"):
            score += 10
        if title in ("魔兽世界",) or title.startswith("World of Warcraft"):
            score += 5
        elif "魔兽世界" in title or "World of Warcraft" in title:
            score += 3
        if score >= 10 and score > best_score:
            best_score = score
            best = (hwnd, title, exe)
    return best


def virtual_key(name):
    key = name.strip().upper()
    if len(key) == 1 and ("0" <= key <= "9" or "A" <= key <= "Z"):
        return ord(key)
    raise SystemExit(f"不认识的按键: {name}")


GA_ROOT = 2
SW_SHOW = 5
HWND_NOTOPMOST = wintypes.HWND(-2)
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040
LSFW_UNLOCK = 2


def foreground():
    return int(user32.GetForegroundWindow() or 0)


def root_window(hwnd):
    hwnd = int(hwnd or 0)
    if not hwnd:
        return 0
    return int(user32.GetAncestor(hwnd, GA_ROOT) or hwnd)


def same_window(left, right):
    left, right = root_window(left), root_window(right)
    return left != 0 and left == right


def focus(hwnd):
    hwnd = root_window(hwnd)
    if not hwnd or not user32.IsWindow(hwnd):
        return False
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
    if same_window(foreground(), hwnd):
        return True
    fg = foreground()
    current = kernel32.GetCurrentThreadId()
    pid = wintypes.DWORD()
    attached = []
    for other in (fg, hwnd):
        if not other:
            continue
        tid = user32.GetWindowThreadProcessId(other, ctypes.byref(pid))
        if tid and tid != current and tid not in attached:
            if user32.AttachThreadInput(tid, current, True):
                attached.append(tid)
    try:
        # 先按下 Alt、解开前台锁，系统才允许后台进程改前台。Alt 必须松开。
        user32.LockSetForegroundWindow(LSFW_UNLOCK)
        user32.keybd_event(VK_MENU, 0x38, 0, 0)
        user32.ShowWindow(hwnd, SW_SHOW)
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
        user32.SetFocus(hwnd)
        user32.SwitchToThisWindow(hwnd, True)
        time.sleep(0.06)
    finally:
        user32.keybd_event(VK_MENU, 0x38, KEYEVENTF_KEYUP, 0)
        for tid in attached:
            user32.AttachThreadInput(tid, current, False)
    return same_window(foreground(), hwnd)


def key_event(scan, up):
    event = INPUT()
    event.type = INPUT_KEYBOARD
    event.u.ki.wScan = scan
    event.u.ki.dwFlags = KEYEVENTF_SCANCODE | (KEYEVENTF_KEYUP if up else 0)
    return user32.SendInput(1, ctypes.byref(event), ctypes.sizeof(event)) == 1


def tap(vk):
    # 必须先把游戏切到前台。扫描码的按下、按住、回弹会进入 DirectInput。
    scan = user32.MapVirtualKeyW(vk, 0)
    if not key_event(scan, False):
        return False
    time.sleep(random.uniform(KEY_DOWN_MIN, KEY_DOWN_MAX))
    if not key_event(scan, True):
        key_event(scan, True)
        return False
    time.sleep(random.uniform(KEY_UP_MIN, KEY_UP_MAX))
    return True


def find_return():
    want = os.path.basename(RETURN_EXE).lower()
    found = []
    title_buf = ctypes.create_unicode_buffer(512)

    @WNDENUMPROC
    def visit(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        if os.path.basename(image_path(hwnd)).lower() != want:
            return True
        user32.GetWindowTextW(hwnd, title_buf, 512)
        if title_buf.value:
            found.append(int(hwnd))
        return True

    user32.EnumWindows(visit, 0)
    return found[0] if found else 0


def press(key):
    found = find_wow()
    if not found:
        print("没找到魔兽世界窗口")
        return False
    hwnd, title, _exe = found
    if not focus(hwnd):
        print(f"没能把「{title}」切到前台，这次不按键")
        return False
    ok = tap(virtual_key(key))
    flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    user32.SetWindowPos(root_window(hwnd), HWND_NOTOPMOST, 0, 0, 0, 0, flags)
    back = find_return()
    if not back:
        print(f"没找到 {RETURN_EXE} 窗口")
    elif not same_window(back, hwnd) and not focus(back):
        print(f"没能切回 {RETURN_EXE}")
    if not ok:
        print(f"向「{title}」发送 {key} 失败（{kernel32.GetLastError()}）")
    return ok


def stop_requested():
    ctrl = user32.GetAsyncKeyState(VK_CONTROL) & 0x8000
    f12 = user32.GetAsyncKeyState(VK_F12) & 0x8000
    return bool(ctrl and f12)


def wait(seconds):
    end = time.monotonic() + seconds
    while True:
        if stop_requested():
            print("\n已停止")
            return False
        left = end - time.monotonic()
        if left <= 0:
            return True
        time.sleep(min(0.05, left))


def drain(items):
    try:
        while True:
            items.get_nowait()
    except queue.Empty:
        return


def read_loop(stream, frames, items, stop):
    while not stop.is_set():
        try:
            data = stream.read(frames, exception_on_overflow=False)
        except Exception as exc:
            items.put(("err", str(exc)))
            return
        items.put(("rms", time.monotonic(), rms_bytes(data)))


def mode_name(mode):
    return {"arming": "等待初始", "fishing": "钓鱼中", "busy": "收竿"}.get(mode, mode)


def throw_line(session, items, dry, text):
    print(f"{text} ({CAST_KEY})")
    if dry or press(CAST_KEY):
        session.confirm_cast(time.monotonic())
        drain(items)
    else:
        session.rollback_cast(time.monotonic())


def act(session, items, action, dry):
    if action in ("cast", "retry"):
        pause = random.uniform(0.4, 1.3)
        print(f"{pause:.1f} 秒后重新抛竿")
        if not wait(pause):
            return False
        text = f"{SILENCE_SEC:.0f} 秒没有水花，重新抛竿" if action == "cast" else "重试抛竿"
        throw_line(session, items, dry, text)
        return True
    if action == "loot":
        react = random.uniform(REACT_MIN, REACT_MAX)
        print(f"听到水花，峰值 {session.last_peak:.4f}，{react:.1f} 秒后收竿 ({LOOT_KEY})")
        if not wait(react):
            return False
        if not dry and not press(LOOT_KEY):
            session.rollback_loot(time.monotonic())
            return True
        delay = random.uniform(RECAST_MIN, RECAST_MAX)
        print(f"{delay:.1f} 秒后继续抛竿")
        if not wait(delay):
            return False
        print(f"继续抛竿 ({CAST_KEY})")
        if dry or press(CAST_KEY):
            session.finish_loot(time.monotonic())
            drain(items)
        else:
            session.rollback_cast(time.monotonic())
        return True
    if action == "ignore":
        print(f"水花峰值 {session.last_peak:.4f}，抛竿后 {IGNORE_SEC:.0f} 秒内，忽略")
    elif action == "heard":
        print(f"短促声音峰值 {session.last_peak:.4f}（还没进入咬钩判定）")
    return True


def loop(session, items, dry):
    next_status = 0.0
    recent_peak = 0.0
    while True:
        if stop_requested():
            print("\n已停止")
            return
        try:
            item = items.get(timeout=0.3)
        except queue.Empty:
            continue
        if item[0] == "err":
            print("读取系统声音失败:", item[1])
            return
        now, rms = item[1], item[2]
        recent_peak = max(recent_peak, rms)
        action = session.update(now, rms)
        if action is not None:
            recent_peak = 0.0
            if not act(session, items, action, dry):
                return
            continue
        if now >= next_status:
            silent = 0 if session.last_water is None else now - session.last_water
            print(
                f"{mode_name(session.mode)}  音量 {rms:.4f}  这5秒最高 {recent_peak:.4f}"
                f"  阈值 {session.meter.threshold:.4f}  无水花 {silent:.0f} 秒"
            )
            recent_peak = 0.0
            next_status = now + 5


def run(threshold, dry):
    if SILENCE_SEC < 5:
        raise SystemExit("SILENCE_SEC 至少要 5 秒，避免不停抛竿")
    if not RECAST_MIN <= RECAST_MAX:
        raise SystemExit("RECAST_MIN 不能大于 RECAST_MAX")
    if not dry:
        if not os.path.basename(RETURN_EXE).strip():
            raise SystemExit("RETURN_EXE 不能为空")
        if not find_return():
            raise SystemExit(f"没找到 {RETURN_EXE} 的窗口，脚本不启动")
    pa, stream, frames, dev = open_stream()
    stop = threading.Event()
    worker = None
    try:
        if threshold <= 0:
            raise SystemExit("阈值要大于 0")
        print(f"阈值 {threshold:.4f}")
        print(f"正在听: {dev['name']}")
        if dry:
            print("只监听，不会按键。低于阈值的入水和收竿水花不会报。Ctrl+F12 结束。")
        else:
            print(
                f"启动即视为未钓鱼，立刻把游戏切到前台按 1，然后回到 {RETURN_EXE}。抛竿 {IGNORE_SEC:.0f} 秒后才认咬钩，"
                f"然后按 F，1 到 2 秒后再按 1。{SILENCE_SEC:.0f} 秒没有水花会再按 1。Ctrl+F12 结束。"
            )
            found = find_wow()
            if found:
                print(f"游戏窗口: {found[1]}  {found[2]}")
            else:
                print("还没找到魔兽世界窗口，要按键时会再找。")
        session = Session(threshold)
        items = queue.Queue()
        worker = threading.Thread(target=read_loop, args=(stream, frames, items, stop), daemon=True)
        worker.start()
        if not dry:
            throw_line(session, items, dry, "未钓鱼，抛竿")
        loop(session, items, dry)
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        stop.set()
        if worker is not None:
            worker.join(timeout=1)
        stream.close()
        pa.terminate()


def doctor():
    pa, stream, frames, dev = open_stream()
    try:
        samples = []
        started = time.perf_counter()
        for _ in range(20):
            data = stream.read(frames, exception_on_overflow=False)
            samples.append(rms_bytes(data))
        spent = (time.perf_counter() - started) / 20
        print(f"设备: {dev['name']}")
        print(
            f"音量 min {min(samples):.4f}  max {max(samples):.4f}"
            f"  avg {sum(samples) / len(samples):.4f}"
        )
        print(f"每块 {spent * 1000:.0f} ms（块长 {BLOCK_SEC * 1000:.0f} ms）")
        if spent > BLOCK_SEC * 1.5:
            print("读音频偏慢，水花判断会滞后。")
        found = find_wow()
        if found:
            print(f"窗口: {found[1]}  {found[2]}")
        else:
            print("没有找到魔兽世界窗口")
    finally:
        stream.close()
        pa.terminate()


def main(argv):
    parser = argparse.ArgumentParser(description="魔兽世界无限服钓鱼助理")
    parser.add_argument("--monitor", action="store_true", help="只显示音量，不向游戏按键")
    parser.add_argument("--check", action="store_true", help="自检，并查看音频设备和游戏窗口")
    parser.add_argument("--threshold", type=float, default=THRESHOLD, help="音量阈值，默认只认咬钩")
    args = parser.parse_args(argv)
    if args.threshold <= 0:
        raise SystemExit("阈值要大于 0")
    self_check()
    if args.check:
        print("自检通过")
        doctor()
        return
    run(args.threshold, args.monitor)


if __name__ == "__main__":
    main(sys.argv[1:])
