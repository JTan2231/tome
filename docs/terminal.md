# Terminal and display

Tome reads keys and text from the terminal and draws the editor view. It saves
the terminal settings for restoration when the session ends. Tome uses virtual
terminal escape sequences and supports keyboard input. It ignores mouse reports.
[Ghostty VT reference](https://ghostty.org/docs/vt/reference)

## Open and restore the terminal

Connect standard input and standard output to a terminal before starting the
interactive editor. If either is missing, Tome reports `tome: NotATerminal`
and exits with status 1. Run Tome from a terminal to start an interactive
session. On Windows, use Windows Terminal or a console host that supports
[virtual terminal sequences](https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences).

At startup, Tome switches the terminal to raw mode, opens the alternate
screen, and enables bracketed paste. It translates terminal key sequences and
UTF-8 keyboard input into editor events. [Edit text](editing.md)

Tome attempts to restore terminal settings and leave the alternate screen
after normal exit, an I/O error, or a handled interruption. On macOS and Linux,
Tome handles `SIGHUP`, `SIGINT`, `SIGQUIT`, and `SIGTERM`. On Windows, it handles
`Ctrl+Break`. An I/O error or handled interruption discards unsaved edits.

Tome ignores `Ctrl+C` and `Ctrl+Z` as keystrokes. To close the editor from
normal mode, use a quit command. [Save and recovery](workspace.md#save-and-recovery)

## Read the viewport

The editor scrolls vertically and horizontally to keep the cursor visible.
Each line occupies one row and clips at the viewport edges. A blank row
separates adjacent files. The cursor skips this row when you move between
files. [Move the cursor](editing.md#move-the-cursor)

Tome wraps in both directions when the readable files contain more logical
lines than the content area has rows. This count excludes separator rows.
When the lines fit, movement stops at the ends of the workspace.
[Workspace order](workspace.md#startup-and-discovery)

Line numbers appear in the left gutter and start at 1 in each file. The status
row shows the current mode, the `[+]` marker for unsaved edits, and the file
under the cursor. It also shows the line number and display column, both
starting at 1. The last row shows prompts, messages, or key hints. A block
cursor indicates normal or visual mode. A bar cursor indicates insert mode or
prompt entry.

Tome uses 24 rows or 80 columns when it cannot get that dimension from the
terminal. It reserves two rows below the content area. Tome clears the editor
view if the terminal has fewer than 3 rows or fewer than 2 columns. Enlarge
the terminal to see the editor again.

Tome displays tabs at four-column stops. It assigns widths to Unicode scalars,
including common wide characters and combining marks. The cursor can appear
out of place on joined emoji and some scripts.

Tome displays ASCII control bytes as caret notation, except for tabs and line
endings. It displays replacement characters for malformed UTF-8 and certain
Unicode controls. These display rules preserve the file's bytes and prevent
file contents from sending terminal escape sequences.

## Generate a frame

`Editor.renderFrame` takes the viewport dimensions and returns a complete ANSI
frame. The editor owns the returned bytes, which stay valid until the next
frame or editor shutdown. The terminal loop writes the frame to standard
output. The measurement harness can generate it without terminal I/O.
[Performance measurement](measurement.md), [Source layout](source-layout.md)

The editor redraws when a background result changes the frame. See
[Document readiness](workspace.md#document-readiness) for how nearby files load.

## Color source code

Tome colors Zig (`.zig`, `.zon`) and C (`.c`, `.h`) with built-in scanners.
These scanners run without language tools. The build compiles the palette from
`src/syntax_theme.json`. This file uses the ANSI color subset of Tree-sitter's
theme format.

The editor schedules one background scan at a time and gives the current file
priority over other visible files. The scanner reads a snapshot of the
buffer, including unsaved edits. After an edit, the editor adjusts surviving
color ranges and displays them while a new scan runs. The editor applies the
result only if the buffer is still loaded at the scanned revision.

Tome scans buffers up to 1 MiB. A scan can produce at most 65,536 color ranges
per file. If the scan exceeds that limit or fails, Tome draws the file without
syntax colors. Tome can scan the file again after an edit. The color ranges
share the workspace cache with file content.
[Cache and file limits](workspace.md#cache-and-file-limits)
