#!/usr/bin/env python3
"""Exercise the real terminal application using only Python's standard library.

Run after `zig build`: python3 tests/pty_smoke.py
"""

import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
    Path(__file__).resolve().parents[1] / "zig-out/bin/tome"
)


class Editor:
    def __init__(self, path=None, *, cwd=None, rows=24, columns=80):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.output = bytearray()
        self.resize(rows, columns)
        self.process = subprocess.Popen(
            [str(BINARY)] + ([] if path is None else [str(path)]),
            cwd=cwd,
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env={**os.environ, "TERM": "xterm-ghostty"},
            start_new_session=True,
        )
        try:
            self.expect(b"NORMAL")
        except BaseException:
            self.__exit__()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        os.close(self.master)
        os.close(self.slave)

    def resize(self, rows, columns):
        self.rows = rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, columns, 0, 0))

    def read(self, timeout):
        if not select.select([self.master], [], [], timeout)[0]:
            return
        try:
            chunk = os.read(self.master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                return
            raise
        self.output.extend(chunk)

    def expect(self, needle, start=0, timeout=5):
        deadline = time.monotonic() + timeout
        while needle not in self.output[start:]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f"did not see {needle!r}; exit={self.process.poll()}; "
                    f"last output={bytes(self.output[-1200:])!r}"
                )
            self.read(min(remaining, 0.1))

    def send(self, data, expect=None):
        start = len(self.output)
        os.write(self.master, data)
        if expect is not None:
            self.expect(expect, start)

    def insert(self, text):
        self.send(b"i", b"INSERT")
        self.send(text)
        self.send(b"\x1b", b"NORMAL")

    def frame_after(self, keys=b""):
        """Synchronize after normal-mode keys and return one complete frame."""
        self.send(keys + b":", f"\x1b[{self.rows};1H\x1b[2K:".encode())
        start = self.output.rfind(b"\x1b[?2026h")
        self.expect(b"\x1b[?2026l", start)
        frame = bytes(self.output[start:])
        self.send(b"\x1b", b"\x1b[?2026l")
        return frame

    def write(self, command="w"):
        # Wait for the prompt so an earlier save message redrawn during motion
        # cannot be mistaken for confirmation of this write.
        self.send(f":{command}".encode(),
                  f"\x1b[{self.rows};1H\x1b[2K:{command}".encode())
        self.send(b"\r", b"Written")

    def quit(self, force=False):
        self.send(b":q!\r" if force else b":q\r")
        self.finished()

    def finished(self):
        deadline = time.monotonic() + 5
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read(0.05)
        assert self.process.poll() is not None, "editor did not exit"
        self.read(0)
        assert self.process.returncode == 0, bytes(self.output[-1200:])
        assert termios.tcgetattr(self.slave) == self.original, "terminal mode not restored"
        assert b"\x1b[?1049l" in self.output, "alternate screen not restored"
        assert b"\x1b[?2004l" in self.output, "bracketed paste not disabled"


def new_file_and_unsaved_guard(directory):
    path = directory / "new.txt"
    with Editor(path) as editor:
        editor.insert(b"hello\rworld")
        editor.send(b":q\r", b"Unsaved")
        assert editor.process.poll() is None
        assert not path.exists(), "editing wrote the file before :w"
        editor.write()
        assert path.read_bytes() == b"hello\nworld"
        editor.quit()


def utf8_backspace_and_arrows(directory):
    path = directory / "unicode.txt"
    path.write_bytes(b"alpha\nbeta\n")
    with Editor(path) as editor:
        editor.send(b"i", b"INSERT")
        editor.send("héλ".encode() + b"\x7f")
        editor.send(b"\x1b[D!\x1b[C\r")
        editor.send(b"\x1b", b"NORMAL")
        editor.write()
        assert path.read_bytes() == "h!é\nalpha\nbeta\n".encode()
        editor.quit()


def preserve_crlf(directory):
    path = directory / "windows.txt"
    path.write_bytes(b"one\r\ntwo\r\n")
    with Editor(path) as editor:
        editor.insert(b"zero\r")
        editor.write()
        assert path.read_bytes() == b"zero\r\none\r\ntwo\r\n"
        editor.quit()


def normal_motion_and_delete(directory):
    path = directory / "motion.txt"
    path.write_bytes(b"first\nsecond")
    with Editor(path) as editor:
        editor.send(b"jli", b"INSERT")
        editor.send(b"X\x1b[3~")
        editor.send(b"\x1b", b"NORMAL")
        editor.write()
        assert path.read_bytes() == b"first\nsXcond"
        editor.quit()


def append_unicode_and_line_end(directory):
    path = directory / "append.txt"
    path.write_bytes("éx\r\nnext".encode())
    with Editor(cwd=directory) as editor:
        editor.send(b"a", b"INSERT")
        editor.send(b"!")
        editor.send(b"\x1b", b"NORMAL")
        editor.write()
        assert path.read_bytes() == "é!x\r\nnext".encode()
        # Appending at the insertion position after a line must not cross CRLF.
        editor.send(b"$a", b"INSERT")
        editor.send(b"END")
        editor.send(b"\x1b", b"NORMAL")
        editor.write()
        assert path.read_bytes() == "é!xEND\r\nnext".encode()
        editor.quit()


def undo_redo_groups_and_saved_version(directory):
    path = directory / "history.txt"
    original = b"one\r\ntwo"
    path.write_bytes(original)
    with Editor(cwd=directory) as editor:
        editor.insert(b"alpha\r")
        frame = editor.frame_after(b"u")
        assert b"NORMAL  " in frame and b"NORMAL [+]" not in frame, frame
        assert b"alpha" not in frame, "undo did not remove the entire insert session"
        frame = editor.frame_after(b"r")
        assert b"NORMAL [+]" in frame and b"alpha" in frame, frame
        editor.write()
        assert path.read_bytes() == b"alpha\r\n" + original
        frame = editor.frame_after(b"u")
        assert b"NORMAL [+]" in frame, "undo past the saved version was marked clean"
        frame = editor.frame_after(b"r")
        assert b"NORMAL  " in frame and b"NORMAL [+]" not in frame, frame
        editor.send(b"u")
        editor.insert(b"NEW")
        # A new edit replaces the old redo branch; r must leave it intact.
        editor.send(b"r")
        editor.write()
        assert path.read_bytes() == b"NEW" + original
        editor.quit()


def literal_paste_and_discard(directory):
    path = directory / "paste.txt"
    original = b"original"
    path.write_bytes(original)
    with Editor(path) as editor:
        # Pasting command-like text in normal mode must not execute it.
        editor.send(b"\x1b[200~:q!\n\x1b[201~")
        editor.send(b"i", b"INSERT")
        payload = ":q!\nλ\tend".encode()
        editor.send(b"\x1b[200~" + payload + b"\x1b[201~")
        editor.send(b"\x1b", b"NORMAL")
        editor.write()
        assert path.read_bytes() == payload + original
        editor.insert(b"discard this")
        editor.quit(force=True)
        assert path.read_bytes() == payload + original


def visual_character_yank_and_paste(directory):
    path = directory / "visual-unicode.txt"
    path.write_bytes("aé界z\n".encode())
    with Editor(path) as editor:
        editor.send(b"lv\x1b[C", b"VISUAL")
        editor.expect(b"\x1b[7m" + "é界".encode() + b"\x1b[27m")
        editor.send(b"y", b"NORMAL")
        # P inserts before the end-of-line position; p inserts after the a.
        editor.send(b"$P0p")
        editor.write()
        assert path.read_bytes() == "aé界é界zé界\n".encode()
        editor.quit()


def visual_line_yank_does_not_modify(directory):
    path = directory / "visual-lines.txt"
    original = b"one\ntwo"
    path.write_bytes(original)
    with Editor(path) as editor:
        editor.send(b"Vj", b"VISUAL LINE")
        editor.expect(b"\x1b[7mone")
        editor.expect(b"\x1b[7mtwo")
        editor.send(b"y", b"NORMAL")
        editor.quit()
        assert path.read_bytes() == original


def line_yank_and_paste_without_final_newline(directory):
    path = directory / "line-paste.txt"
    path.write_bytes(b"one\ntwo")
    with Editor(path) as editor:
        editor.send(b"jYkP")
        editor.write()
        assert path.read_bytes() == b"two\none\ntwo"
        editor.quit()


def line_yank_and_paste_crlf(directory):
    path = directory / "line-paste-crlf.txt"
    path.write_bytes(b"one\r\ntwo\r\n")
    with Editor(path) as editor:
        editor.send(b"yyp")
        editor.write()
        assert path.read_bytes() == b"one\r\none\r\ntwo\r\n"
        editor.quit()


def visual_delete_and_change(directory):
    path = directory / "visual-edit.txt"
    path.write_bytes(b"abc def\nkeep\n")
    with Editor(path) as editor:
        editor.send(b"vlld")
        editor.write()
        assert path.read_bytes() == b" def\nkeep\n"
        # Deletion also populates the yank register.
        editor.send(b"P0llllvllc", b"INSERT")
        editor.send(b"Z")
        editor.send(b"\x1b", b"NORMAL")
        editor.write()
        assert path.read_bytes() == b"abc Z\nkeep\n"
        editor.quit()


def visual_replace_keeps_register(directory):
    path = directory / "visual-replace.txt"
    path.write_bytes(b"ab xx yy\n")
    with Editor(path) as editor:
        editor.send(b"vly0lllvlp")
        editor.write()
        assert path.read_bytes() == b"ab ab yy\n"
        editor.send(b"0llllllvlP")
        editor.write()
        assert path.read_bytes() == b"ab ab ab\n"
        editor.quit()


def resize_and_signal_cleanup(directory):
    path = directory / "resize.txt"
    path.write_bytes(b"long line " * 20 + b"\n")
    with Editor(path) as editor:
        editor.resize(3, 8)
        editor.send(b"i", b"INSERT")
        editor.resize(1, 1)
        editor.send(b"\x1b")
        editor.read(0.2)
        editor.resize(24, 80)
        editor.send(b"i", b"INSERT")
        editor.process.send_signal(signal.SIGTERM)
        editor.finished()


def failed_save_keeps_original_and_buffer(directory):
    path = directory / "conflict.txt"
    path.write_bytes(b"original")
    with Editor(path) as editor:
        editor.insert(b"unsaved ")
        path.write_bytes(b"changed by another process")
        editor.send(b":w\r", b"Save failed:")
        assert path.read_bytes() == b"changed by another process"
        editor.send(b":q\r", b"Unsaved")
        assert editor.process.poll() is None, "failed save cleared dirty state"
        editor.quit(force=True)
        assert path.read_bytes() == b"changed by another process"



def assert_current(frame, name):
    # The penultimate row is the status margin; filenames in content do not count.
    status = frame.split(b"\x1b[23;1H", 1)[1].split(b"\x1b[24;1H", 1)[0]
    assert b" " + name.encode() + b"\x1b[0m" in status, status


def directory_browse_order_and_margin(directory):
    entries = [
        ("a/nested/z.txt", b"nested-first"),
        ("a/a.txt", b"a-container"),
        ("b/a.txt", b"b-container"),
        ("a.txt", b"root-first"),
        ("z.txt", b"root-last"),
    ]
    for name, content in entries:
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    with Editor(cwd=directory) as editor:
        # Neighbor contents arrive asynchronously after the active file.
        editor.expect(entries[-1][1])
        frame = editor.frame_after()
        assert_current(frame, entries[0][0])
        offsets = [frame.index(content) for _, content in entries]
        assert offsets == sorted(offsets), frame
        assert b"\x1b[2;1H\x1b[2K\x1b[3;1H" in frame, frame
        for name, _ in entries[1:]:
            assert_current(editor.frame_after(b"j"), name)
        assert_current(editor.frame_after(b"j" * 8), entries[-1][0])
        for name, _ in reversed(entries[:-1]):
            assert_current(editor.frame_after(b"k"), name)
        assert_current(editor.frame_after(b"k" * 8), entries[0][0])
        editor.quit()


def filename_start_and_workspace_writes(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"alpha")
    second.write_bytes(b"bravo")
    with Editor("b.txt", cwd=directory) as editor:
        assert_current(editor.frame_after(), "b.txt")
        editor.insert(b"B")
        assert_current(editor.frame_after(b"k0"), "a.txt")
        editor.insert(b"A")
        editor.write("wt")
        assert first.read_bytes() == b"Aalpha"
        assert second.read_bytes() == b"bravo", ":wt saved another file"
        editor.send(b":q\r", b"Unsaved")
        assert editor.process.poll() is None
        editor.write()
        assert second.read_bytes() == b"Bbravo"
        editor.quit()


def file_jumps_and_independent_undo(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"  a-first\na-last")
    second.write_bytes(b"b-first\n  b-last")
    with Editor(cwd=directory) as editor:
        frame = editor.frame_after(b"G")
        assert_current(frame, "a.txt")
        assert b"NORMAL  2:1  " in frame, frame
        frame = editor.frame_after(b"G")
        assert_current(frame, "b.txt")
        assert b"NORMAL  2:3  " in frame, frame
        editor.insert(b"B")
        frame = editor.frame_after(b"gg")
        assert_current(frame, "b.txt")
        assert b"NORMAL [+]  1:1  " in frame, frame
        frame = editor.frame_after(b"gg")
        assert_current(frame, "a.txt")
        assert b"NORMAL  1:3  " in frame, frame
        editor.insert(b"A")
        editor.frame_after(b"u")
        editor.write()
        assert first.read_bytes() == b"  a-first\na-last"
        assert second.read_bytes() == b"b-first\n  Bb-last"
        frame = editor.frame_after(b"GG")
        assert_current(frame, "b.txt")
        editor.send(b"u")
        editor.write()
        assert second.read_bytes() == b"b-first\n  b-last"
        editor.quit()


def single_short_file_does_not_repeat(directory):
    path = directory / "only.txt"
    path.write_bytes(b"one-short-line")
    with Editor(cwd=directory) as editor:
        frame = editor.frame_after(b"j" * 40 + b"k" * 40)
        assert frame.count(b"one-short-line") == 1, frame
        assert_current(frame, "only.txt")
        editor.insert(b"still-first:")
        editor.write()
        assert path.read_bytes() == b"still-first:one-short-line"
        editor.quit()


def long_file_wraps_both_directions(directory):
    path = directory / "long.txt"
    lines = [f"line-{index:02d}".encode() for index in range(25)]
    path.write_bytes(b"\n".join(lines))
    with Editor(cwd=directory) as editor:
        editor.frame_after(b"k0")
        editor.insert(b"last:")
        editor.frame_after(b"j0")
        editor.insert(b"first:")
        editor.write()
        lines[0] = b"first:" + lines[0]
        lines[-1] = b"last:" + lines[-1]
        assert path.read_bytes() == b"\n".join(lines)
        editor.quit()


def long_workspace_wraps_between_files(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    a_lines = [f"a-{index:02d}".encode() for index in range(12)]
    b_lines = [f"b-{index:02d}".encode() for index in range(12)]
    first.write_bytes(b"\n".join(a_lines))
    second.write_bytes(b"\n".join(b_lines))
    with Editor(cwd=directory) as editor:
        editor.expect(b_lines[0])
        assert_current(editor.frame_after(b"k0"), "b.txt")
        editor.insert(b"last:")
        assert_current(editor.frame_after(b"j0"), "a.txt")
        editor.insert(b"first:")
        editor.write()
        a_lines[0] = b"first:" + a_lines[0]
        b_lines[-1] = b"last:" + b_lines[-1]
        assert first.read_bytes() == b"\n".join(a_lines)
        assert second.read_bytes() == b"\n".join(b_lines)
        editor.quit()


def selections_stay_in_file_and_register_crosses_files(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"alpha")
    second.write_bytes(b"bravo")
    with Editor(cwd=directory) as editor:
        # Neither an operator motion nor a visual selection crosses a boundary.
        editor.send(b"djVjy")
        assert_current(editor.frame_after(b"j0"), "b.txt")
        editor.send(b"P")
        editor.write()
        assert first.read_bytes() == b"alpha"
        assert second.read_bytes() == b"alpha\nbravo"
        editor.quit()


def workspace_save_continues_after_conflict(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"alpha")
    second.write_bytes(b"bravo")
    with Editor(cwd=directory) as editor:
        editor.insert(b"A")
        editor.frame_after(b"j0")
        editor.insert(b"B")
        first.write_bytes(b"external")
        editor.send(b":w\r", b"Save failed:")
        assert first.read_bytes() == b"external"
        assert second.read_bytes() == b"Bbravo", "a failed save blocked other files"
        editor.send(b":q\r", b"Unsaved")
        editor.quit(force=True)


def oversized_neighbor_is_skipped(directory):
    large = directory / "a.big"
    with large.open("wb") as handle:
        handle.truncate(65 * 1024 * 1024)
    small = directory / "b.txt"
    small.write_bytes(b"editable")
    with Editor(cwd=directory) as editor:
        assert_current(editor.frame_after(), "b.txt")
        editor.insert(b"still ")
        editor.write()
        assert small.read_bytes() == b"still editable"
        assert large.stat().st_size == 65 * 1024 * 1024
        editor.quit()


def empty_workspace_is_browsable(directory):
    with Editor(cwd=directory) as editor:
        editor.frame_after(b"jkhl")
        editor.quit()
    assert not list(directory.iterdir()), "empty browsing invented a file"



def search_forward_repeat_wrap_and_literals(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"start Needle n.edle needle")
    second.write_bytes(b"last needle")
    with Editor(cwd=directory) as editor:
        # Literal punctuation does not match the earlier capitalized word.
        editor.send(b"/n.edle\r", b"NORMAL  1:14  ")
        assert_current(editor.frame_after(), "a.txt")
        # Matching is case-sensitive; the lowercase word follows both above.
        editor.send(b"/needle\r", b"NORMAL  1:21  ")
        assert_current(editor.frame_after(), "a.txt")
        editor.send(b"n", b"NORMAL  1:6  ")
        assert_current(editor.frame_after(), "b.txt")
        editor.send(b"n", b"Search wrapped")
        frame = editor.frame_after()
        assert_current(frame, "a.txt")
        assert b"NORMAL  1:21  " in frame, frame
        # A no-match search leaves the last successful position untouched.
        editor.send(b"/missing\r", b"Pattern not found")
        frame = editor.frame_after()
        assert_current(frame, "a.txt")
        assert b"NORMAL  1:21  " in frame, frame
        editor.quit()
    assert first.read_bytes() == b"start Needle n.edle needle"
    assert second.read_bytes() == b"last needle"


def search_unicode_backspace_and_insert_literals(directory):
    path = directory / "unicode.txt"
    path.write_bytes("start héλ end".encode())
    with Editor(cwd=directory) as editor:
        # One backspace removes a whole scalar from the search prompt.
        editor.send(b"/" + "hé界".encode() + b"\x7f" + "λ".encode() + b"\r",
                    b"NORMAL  1:7  ")
        editor.insert(b"/n")
        editor.write()
        assert path.read_bytes() == "start /nhéλ end".encode()
        editor.quit()


def search_visual_stays_in_current_file(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"a target z")
    second.write_bytes(b"elsewhere")
    with Editor(cwd=directory) as editor:
        editor.send(b"v/target\r", b"VISUAL  1:3  ")
        start = editor.output.rfind(b"\x1b[?2026h")
        editor.expect(b"\x1b[?2026l", start)
        assert b"\x1b[7ma t\x1b[27m" in editor.output[start:], editor.output[start:]
        frame = editor.frame_after()
        assert_current(frame, "a.txt")
        # frame_after uses : and Escape, so start a fresh visual selection.
        editor.send(b"v/elsewhere\r", b"Pattern not found")
        frame = editor.frame_after()
        assert_current(frame, "a.txt")
        editor.quit()
    assert first.read_bytes() == b"a target z"
    assert second.read_bytes() == b"elsewhere"


def search_unsaved_buffers_across_files(directory):
    first = directory / "a.txt"
    second = directory / "b.txt"
    first.write_bytes(b"alpha")
    second.write_bytes(b"bravo")
    with Editor(cwd=directory) as editor:
        editor.insert(b"unsaved ")
        assert_current(editor.frame_after(b"j0"), "b.txt")
        editor.send(b"/unsaved\r", b"Search wrapped")
        frame = editor.frame_after()
        assert_current(frame, "a.txt")
        assert b"NORMAL [+]  1:1  " in frame, frame
        assert first.read_bytes() == b"alpha", "search saved the dirty buffer"
        editor.quit(force=True)
    assert first.read_bytes() == b"alpha"
    assert second.read_bytes() == b"bravo"


def search_cancel_and_supersede_pending_navigation(directory):
    first = directory / "a.txt"
    far = directory / "z.txt"
    # Keep the large file outside the initial viewport, and make a distant hit.
    original = b"start near\n" + b"visible\n" * 30
    first.write_bytes(original)
    with far.open("wb") as handle:
        for _ in range(512):
            handle.write(b"padding\n" * 8192)
        handle.write(b"far-target\n")
    with Editor(cwd=directory) as editor:
        # Canceling prompt entry does not change the cursor or remembered query.
        editor.send(b"/far-target\x1b", b"NORMAL  1:1  ")
        # Input following Enter must supersede any eventual distant jump.
        editor.send(b"/far-target\rilocal-", b"INSERT")
        editor.send(b"\x1b", b"NORMAL")
        editor.send(b"0", b"NORMAL [+]  1:1  ")
        # A new search also waits for cancellation without losing the new intent.
        editor.send(b"/near\r", b"NORMAL [+]  1:13  ")
        editor.send(b"/far-target\rh", b"NORMAL [+]  1:12  ")
        editor.send(b"/near\r", b"NORMAL [+]  1:13  ")
        frame = editor.frame_after()
        assert_current(frame, "a.txt")
        editor.write()
        assert first.read_bytes() == b"local-" + original
        editor.quit()


def search_reports_incomplete_coverage(directory):
    first = directory / "a.txt"
    large = directory / "z.big"
    first.write_bytes(b"searchable\n" + b"visible\n" * 30)
    with large.open("wb") as handle:
        handle.truncate(65 * 1024 * 1024)
    with Editor(cwd=directory) as editor:
        editor.send(b"/absent\r", b"Search incomplete")
        assert_current(editor.frame_after(), "a.txt")
        editor.quit()
    assert large.stat().st_size == 65 * 1024 * 1024

def main():
    if not BINARY.is_file():
        raise SystemExit(f"Build the editor first with `zig build`: missing {BINARY}")
    cases = [new_file_and_unsaved_guard, utf8_backspace_and_arrows,
             preserve_crlf, normal_motion_and_delete,
             append_unicode_and_line_end, undo_redo_groups_and_saved_version,
             literal_paste_and_discard,
             visual_character_yank_and_paste, visual_line_yank_does_not_modify,
             line_yank_and_paste_without_final_newline, line_yank_and_paste_crlf,
             visual_delete_and_change, visual_replace_keeps_register,
             resize_and_signal_cleanup,
             failed_save_keeps_original_and_buffer,
             directory_browse_order_and_margin,
             filename_start_and_workspace_writes,
             file_jumps_and_independent_undo,
             single_short_file_does_not_repeat,
             long_file_wraps_both_directions,
             long_workspace_wraps_between_files,
             selections_stay_in_file_and_register_crosses_files,
             workspace_save_continues_after_conflict,
             oversized_neighbor_is_skipped,
             empty_workspace_is_browsable,
             search_forward_repeat_wrap_and_literals,
             search_unicode_backspace_and_insert_literals,
             search_visual_stays_in_current_file,
             search_unsaved_buffers_across_files,
             search_cancel_and_supersede_pending_navigation,
             search_reports_incomplete_coverage]
    with tempfile.TemporaryDirectory(prefix="tome-pty-") as temporary:
        for case in cases:
            directory = Path(temporary) / case.__name__
            directory.mkdir()
            case(directory)
            print(f"PASS {case.__name__}", flush=True)
    print(f"{len(cases)} PTY integration tests passed")


if __name__ == "__main__":
    main()
