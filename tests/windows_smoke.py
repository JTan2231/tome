#!/usr/bin/env python3
"""Exercise the Windows editor through ConPTY using Python's standard library.

Run on Windows 10 1809 or later after building:
    python tests/windows_smoke.py zig-out/bin/tome.exe

The child checks console modes and code pages before and after each editor run.
ConPTY setup follows Microsoft's documented pseudoconsole lifecycle:
https://learn.microsoft.com/windows/console/creating-a-pseudoconsole-session
"""

import ctypes
import os
from ctypes import wintypes as wt
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


if sys.platform != "win32":
    raise SystemExit("windows_smoke.py requires Windows (use pty_smoke.py on POSIX)")

import msvcrt

kernel = ctypes.WinDLL("kernel32", use_last_error=True)
HANDLE = wt.HANDLE
SIZE_T = ctypes.c_size_t
LPVOID = ctypes.c_void_p


class COORD(ctypes.Structure):
    _fields_ = [("X", wt.SHORT), ("Y", wt.SHORT)]


class STARTUPINFO(ctypes.Structure):
    _fields_ = [
        ("cb", wt.DWORD), ("lpReserved", wt.LPWSTR),
        ("lpDesktop", wt.LPWSTR), ("lpTitle", wt.LPWSTR),
        ("dwX", wt.DWORD), ("dwY", wt.DWORD),
        ("dwXSize", wt.DWORD), ("dwYSize", wt.DWORD),
        ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD),
        ("dwFillAttribute", wt.DWORD), ("dwFlags", wt.DWORD),
        ("wShowWindow", wt.WORD), ("cbReserved2", wt.WORD),
        ("lpReserved2", LPVOID), ("hStdInput", HANDLE),
        ("hStdOutput", HANDLE), ("hStdError", HANDLE),
    ]


class STARTUPINFOEX(ctypes.Structure):
    _fields_ = [("StartupInfo", STARTUPINFO), ("lpAttributeList", LPVOID)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", HANDLE), ("hThread", HANDLE),
                ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD)]


def bind(name, result, *arguments):
    function = getattr(kernel, name)
    function.restype = result
    function.argtypes = arguments
    return function


CreatePipe = bind("CreatePipe", wt.BOOL, ctypes.POINTER(HANDLE),
                  ctypes.POINTER(HANDLE), LPVOID, wt.DWORD)
CreatePseudoConsole = bind("CreatePseudoConsole", ctypes.c_long, COORD, HANDLE,
                           HANDLE, wt.DWORD, ctypes.POINTER(HANDLE))
ClosePseudoConsole = bind("ClosePseudoConsole", None, HANDLE)
InitializeAttributes = bind("InitializeProcThreadAttributeList", wt.BOOL,
                           LPVOID, wt.DWORD, wt.DWORD, ctypes.POINTER(SIZE_T))
UpdateAttribute = bind("UpdateProcThreadAttribute", wt.BOOL, LPVOID, wt.DWORD,
                       SIZE_T, LPVOID, SIZE_T, LPVOID, LPVOID)
DeleteAttributes = bind("DeleteProcThreadAttributeList", None, LPVOID)
CreateProcess = bind("CreateProcessW", wt.BOOL, wt.LPCWSTR, wt.LPWSTR,
                     LPVOID, LPVOID, wt.BOOL, wt.DWORD, LPVOID, wt.LPCWSTR,
                     ctypes.POINTER(STARTUPINFOEX), ctypes.POINTER(PROCESS_INFORMATION))
ReadFile = bind("ReadFile", wt.BOOL, HANDLE, LPVOID, wt.DWORD,
                ctypes.POINTER(wt.DWORD), LPVOID)
WriteFile = bind("WriteFile", wt.BOOL, HANDLE, LPVOID, wt.DWORD,
                 ctypes.POINTER(wt.DWORD), LPVOID)
CloseHandle = bind("CloseHandle", wt.BOOL, HANDLE)
GetExitCodeProcess = bind("GetExitCodeProcess", wt.BOOL, HANDLE, ctypes.POINTER(wt.DWORD))
WaitForSingleObject = bind("WaitForSingleObject", wt.DWORD, HANDLE, wt.DWORD)
TerminateProcess = bind("TerminateProcess", wt.BOOL, HANDLE, wt.UINT)
GetStdHandle = bind("GetStdHandle", HANDLE, wt.DWORD)
SetStdHandle = bind("SetStdHandle", wt.BOOL, wt.DWORD, HANDLE)
CreateFile = bind("CreateFileW", HANDLE, wt.LPCWSTR, wt.DWORD, wt.DWORD,
                  LPVOID, wt.DWORD, wt.DWORD, HANDLE)
GetConsoleMode = bind("GetConsoleMode", wt.BOOL, HANDLE, ctypes.POINTER(wt.DWORD))
GetConsoleCP = bind("GetConsoleCP", wt.UINT)
GetConsoleOutputCP = bind("GetConsoleOutputCP", wt.UINT)


def check(success):
    if not success:
        raise ctypes.WinError(ctypes.get_last_error())


def console_state():
    modes = []
    for identifier in (-10, -11):
        value = wt.DWORD()
        check(GetConsoleMode(GetStdHandle(identifier & 0xffffffff), ctypes.byref(value)))
        modes.append(value.value)
    return (*modes, GetConsoleCP(), GetConsoleOutputCP())


def open_console(name, mode):
    # CI's redirected standard handles can survive ConPTY attachment. These
    # device names open this process's attached console regardless of redirection.
    # Both access bits are needed by GetConsoleMode/SetConsoleMode.
    handle = CreateFile(name, 0xc0000000, 3, None, 3, 0, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        descriptor = msvcrt.open_osfhandle(handle, os.O_BINARY | os.O_RDWR)
    except BaseException:
        CloseHandle(handle)
        raise
    return os.fdopen(descriptor, mode, buffering=0)


def console_child(binary, path):
    with open_console("CONIN$", "rb") as input_file, open_console("CONOUT$", "wb") as output_file:
        check(SetStdHandle((-10) & 0xffffffff, msvcrt.get_osfhandle(input_file.fileno())))
        for identifier in (-11, -12):
            check(SetStdHandle(identifier & 0xffffffff, msvcrt.get_osfhandle(output_file.fileno())))
        before = console_state()
        result = subprocess.run([binary, path], cwd=str(Path(path).parent),
                                stdin=input_file, stdout=output_file, stderr=output_file)
        after = console_state()
        if result.returncode != 0:
            raise SystemExit(result.returncode)
        if after != before:
            raise AssertionError(f"console state not restored: {before} -> {after}")
        output_file.write(b"TOME_CONSOLE_RESTORED\r\n")


class Editor:
    def __init__(self, binary, path):
        self.output = bytearray()
        self.reader_error = None
        self.handles = []
        self.console = HANDLE()
        self.process = PROCESS_INFORMATION()
        self.reader = None
        try:
            input_read, self.input_write = self.pipe()
            self.output_read, output_write = self.pipe()
            result = CreatePseudoConsole(COORD(100, 30), input_read, output_write,
                                         0, ctypes.byref(self.console))
            if result < 0:
                raise OSError(f"CreatePseudoConsole failed: 0x{result & 0xffffffff:08x}")
            size = SIZE_T()
            InitializeAttributes(None, 1, 0, ctypes.byref(size))
            attributes = ctypes.create_string_buffer(size.value)
            check(InitializeAttributes(attributes, 1, 0, ctypes.byref(size)))
            try:
                check(UpdateAttribute(attributes, 0, 0x00020016, self.console,
                                      ctypes.sizeof(HANDLE), None, None))
                startup = STARTUPINFOEX()
                startup.StartupInfo.cb = ctypes.sizeof(startup)
                startup.lpAttributeList = ctypes.cast(attributes, LPVOID)
                command = ctypes.create_unicode_buffer(subprocess.list2cmdline([
                    sys.executable, str(Path(__file__).resolve()), "--console-child",
                    str(binary), str(path),
                ]))
                check(CreateProcess(None, command, None, None, False, 0x00080000,
                                    None, str(path.parent), ctypes.byref(startup),
                                    ctypes.byref(self.process)))
            finally:
                DeleteAttributes(attributes)
            CloseHandle(self.process.hThread)
            for handle in (input_read, output_write):
                CloseHandle(handle)
                self.handles.remove(handle)
            # Drain output independently so synchronous ConPTY writes cannot fill
            # the pipe while the test is sending input or closing the console.
            self.reader = threading.Thread(target=self.read_output, daemon=True)
            self.reader.start()
            self.expect(b"NORMAL")
        except BaseException:
            self.close()
            raise

    def pipe(self):
        read, write = HANDLE(), HANDLE()
        check(CreatePipe(ctypes.byref(read), ctypes.byref(write), None, 0))
        self.handles.extend((read, write))
        return read, write

    def read_output(self):
        buffer = ctypes.create_string_buffer(65536)
        count = wt.DWORD()
        while ReadFile(self.output_read, buffer, len(buffer), ctypes.byref(count), None):
            if not count.value:
                return
            self.output.extend(buffer.raw[:count.value])
        code = ctypes.get_last_error()
        if code not in (6, 109, 995):  # closed handle, broken pipe, canceled I/O
            self.reader_error = code

    def poll(self):
        code = wt.DWORD()
        check(GetExitCodeProcess(self.process.hProcess, ctypes.byref(code)))
        return None if code.value == 259 else code.value

    def expect(self, needle, start=0, timeout=15):
        deadline = time.monotonic() + timeout
        while needle not in self.output[start:]:
            exited = self.poll() is not None
            if exited:
                # The reader can lag the process's final write by one timeslice.
                time.sleep(0.1)
                if needle in self.output[start:]:
                    return
            if time.monotonic() >= deadline or exited or self.reader_error:
                raise AssertionError(
                    f"did not see {needle!r}; exit={self.poll()}; "
                    f"reader_error={self.reader_error}; output={bytes(self.output[-3000:])!r}"
                )
            time.sleep(0.02)

    def send(self, data, expect=None):
        start = len(self.output)
        count = wt.DWORD()
        check(WriteFile(self.input_write, data, len(data), ctypes.byref(count), None))
        assert count.value == len(data), "partial input write"
        if expect is not None:
            self.expect(expect, start)

    def insert(self, data):
        self.send(b"i", b"INSERT")
        self.send(data)
        self.send(b"\x1b", b"NORMAL")

    def save(self):
        self.send(b":w\r", b"Written")

    def quit(self):
        self.send(b":q\r", b"TOME_CONSOLE_RESTORED")
        assert WaitForSingleObject(self.process.hProcess, 10000) == 0, "editor did not exit"
        assert self.poll() == 0, bytes(self.output[-3000:])

    def close(self):
        if self.process.hProcess:
            if WaitForSingleObject(self.process.hProcess, 0) != 0:
                TerminateProcess(self.process.hProcess, 1)
                WaitForSingleObject(self.process.hProcess, 5000)
            CloseHandle(self.process.hProcess)
            self.process.hProcess = None
        if self.console:
            ClosePseudoConsole(self.console)
            self.console = HANDLE()
        for handle in self.handles:
            CloseHandle(handle)
        self.handles.clear()
        if self.reader:
            self.reader.join(timeout=2)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def main():
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[1] / "zig-out/bin/tome.exe"
    )
    result = subprocess.run([str(binary), "--help"], check=True, capture_output=True)
    assert b"Usage: tome" in result.stdout
    with tempfile.TemporaryDirectory(prefix="tome-windows-smoke-") as temporary:
        directory = Path(temporary)
        path = directory / "new caf\u00e9.txt"
        with Editor(binary, path) as editor:
            editor.insert("h\u00e9\u03bb\U0001f600\rworld".encode())
            editor.send(b":q\r", b"Unsaved")
            assert not path.exists(), "editing wrote the file before :w"
            editor.save()
            assert path.read_bytes() == "h\u00e9\u03bb\U0001f600\nworld".encode()
            editor.quit()
        path = directory / "existing.txt"
        path.write_bytes(b"alpha\r\nbeta\r\n")
        with Editor(binary, path) as editor:
            editor.insert(b"zero\r")
            editor.send(b"\x1b[F")  # End of alpha.
            editor.insert(b"!")
            editor.send(b"\x1b[H")  # Home, then insert at the start.
            editor.insert(b">")
            editor.send(b"\x1b[C")  # Right from column 1 to column 2.
            editor.insert(b"*")
            editor.save()
            assert path.read_bytes() == b"zero\r\n>a*lpha!\r\nbeta\r\n"
            editor.quit()
        with Editor(binary, directory) as editor:
            editor.quit()
    print("Windows ConPTY smoke passed: help, UTF-8 and supplementary Unicode, filename, directory startup, navigation, new/existing saves, CRLF, unsaved guard, quit, console restoration")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--console-child":
        console_child(*sys.argv[2:])
    else:
        main()
