# tome

A small terminal text editor written from scratch in Zig. No package dependencies,
terminal library, curses, or mouse support. It uses Zig's standard library and OS
interfaces, with escape sequences targeting Ghostty.

## Build and run

Use **Zig 0.15.2**. On macOS, Homebrew's `zig@0.15` includes the linker fix needed
for recent Apple SDKs:

```sh
brew install zig@0.15
export PATH="$(brew --prefix zig@0.15)/bin:$PATH"
zig build
./zig-out/bin/tome           # browse the current directory
./zig-out/bin/tome notes.txt # start at a particular file
```

Or build and launch in one step:

```sh
zig build run -- notes.txt
```

Run `tome` to browse the current directory recursively, or `tome <filename>` to
start at a particular file. `tome <directory>` browses that directory instead.
Files inside the current directory share that workspace; a file outside it uses
its parent directory as the workspace. An
existing file opens as-is; a missing file starts empty and is created on `:w` or
`:wt`. Its parent directory must already exist. Paths containing spaces work when
quoted. `tome --help` prints a quick reference.

Move past a file's first or last line to enter its neighbor. Each directory visits
its subdirectories first, then its files, with names sorted alphabetically in
each group (case-sensitive byte order). A blank row separates file contents, and
the bottom status margin shows the file under the cursor. The sequence loops in
either direction when its
combined content has more lines than the display area. Short workspaces stop at
their ends, so a lone one-line file does not repeat. Empty directories open an
empty browser without creating a file.

## Keys

The editor starts in **normal** mode. Use **insert** mode to type and **visual**
mode to select text. A block cursor means normal or visual; a bar cursor means
insert or command entry. The status bar shows the current mode and file.

| Key | Action |
| --- | --- |
| `i` | Enter insert state from normal |
| `Escape` | Return to normal, cancel a selection, pending operator, or command entry |
| `h` `j` `k` `l` | Left, down, up, right in normal or visual |
| Arrow keys | Move in any mode |
| Page Up / Page Down | Scroll by a display of content |
| `0` / `$` | Start / end of line in normal or visual |
| Home / End | Start / end of line in any mode |
| `v` / `V` (`Shift+V`) | Select characters / whole lines; move to extend the selection |
| `o` | Move to the other end of a visual selection |
| `y` / `Y` in visual | Yank the selection / all touched lines |
| `yy` or `Y` in normal | Yank the current line |
| `p` / `P` in normal | Paste after / before the cursor, or below / above for whole lines |
| `p` / `P` in visual | Replace the selection with the last yank or deletion |
| `d` or `x` / `c` in visual | Delete the selection / replace it by entering insert mode |
| `dd` / `cc` in normal | Delete / change the current line |
| `x` in normal | Delete the character at the cursor |
| `D` / `C` in normal | Delete / change through the end of the line |
| `y`, `d`, or `c`, then a motion | Yank, delete, or change the range in normal mode |
| Text / Enter / Tab | Insert text / newline / literal tab in insert |
| Backspace / Delete | Delete before / at the cursor in insert |
| `:` | Enter an editor command from normal |

Visual selections include the character under the cursor. Press the same visual
key again to cancel, or the other one to switch between characters and lines.
The supported operator motions are `h`, `j`, `k`, `l`, `0`, `$`, arrows, Home,
and End; vertical motions operate on whole lines. For example, `y$` yanks to
the end of the line and `dj` deletes the current and next lines. Visual selections
and operator motions stay within the current file. Yanked text can be pasted into
another file after navigating there.

Yanks and deletions share one register, kept in memory for this editor session.
It is separate from the system clipboard. Visual replacement keeps that register
so the same text can replace more selections. Yanking alone does not modify the
file.

Type a command and press Enter:

| Command | Action |
| --- | --- |
| `:w` or `:write` | Save all changed files in the workspace |
| `:wt` | Save the file under the cursor |
| `:q` or `:quit` | Quit; refuses if any file has unsaved edits |
| `:q!` or `:quit!` | Quit and discard unsaved edits |

Write and quit are the only commands. Command entry is a prompt within normal
mode. Numeric counts, word motions, block selections, named registers, undo,
search, and configuration are not implemented. The cursor denotes an insertion
position, including after the last character of a line; horizontal movement can
cross line boundaries. This differs from Vim's normal-mode cursor semantics.

## Behavior and limits

- Vertical and horizontal scrolling follow the cursor; lines do not wrap.
- Discovery records file paths, without reading every file into a buffer. Contents
  load as they approach the viewport. Clean buffers use a cache limited to eight
  files or 8 MiB, with the active and currently requested file protected. Unsaved
  buffers stay in memory until saved or discarded, so their size can exceed this
  cache budget.
- The file list is a snapshot taken at startup. Hidden regular files are included;
  `.git` directories and symlinks are skipped during discovery. Unreadable or
  oversized neighbors are skipped when browsing. An explicitly requested file reports an
  open error if it cannot be loaded.
- Files retain their bytes, including whether they have a final newline. Enter
  uses the first newline's LF or CRLF style; new files use LF.
- UTF-8 movement and deletion operate on Unicode scalars. Common wide characters
  and combining marks have display widths, but this is not full grapheme-aware
  editing. Joined emoji and some scripts can have imperfect cursor placement.
- Tabs display at four-column stops. File control bytes are displayed safely;
  they are never interpreted as terminal escape sequences.
- Ghostty's bracketed paste inserts only in insert state. Paste line endings
  normalize to the file's style; non-text control bytes are ignored. A paste in
  normal or visual mode or the command prompt is ignored.
- Saves sync a temporary sibling file, then atomically replace the destination.
  Detected outside changes cause a save error and leave the edits in memory.
  This is a metadata check, not a lock against concurrent writers. Workspace writes
  attempt every changed file even if one fails; successful files stay saved and
  failed files retain their edits. A workspace write is not one atomic transaction.
- Explicitly opened symlinks resolve to their target. Basic permission bits are
  retained. Atomic replacement changes the inode; hard-link sharing, ownership,
  ACLs, and extended attributes are not preserved.
- Files up to 64 MiB can be opened. The buffer is a simple in-memory byte array,
  intended for small files. No crash recovery or autosave yet.
- Normal exits, I/O errors, and handled termination signals restore the terminal.
  Termination signals discard unsaved edits. Ctrl-C and Ctrl-Z are ignored as
  editor input; use `Escape`, then `:q` to quit.

macOS is the initial tested platform. The same source also builds for Linux.
On macOS the binary uses the OS's libSystem; there are no third-party runtime
libraries. Terminal sequences are documented in [Ghostty's VT reference](https://ghostty.org/docs/vt).

## Code and measurement

`src/content/` is the shared content module: file storage, editable buffers,
workspace discovery, caching, and preparation for rendering. `Workspace.ensure`
is the per-file request-to-ready boundary. It returns after the buffer, newline
style, and line count are available and cache eviction has completed. The editor,
viewport traversal, display formatting, and terminal I/O remain in `src/`.

`measurement/` contains a separate harness that calls this same boundary without
starting the editor or terminal. It measures one requested file with a monotonic
clock and reports a JSON record after timing has stopped:

```sh
zig build measure -Doptimize=ReleaseSafe -- notes.txt
```

Discovery and result reporting are outside the interval. This measures complete
file readiness, rather than readiness of an entire viewport. The reusable harness
also supports requests against an existing workspace, distinguishing buffer hits,
loads, and remembered load failures. It does not control the OS file cache.
There are no benchmark scenarios, statistical summaries, or performance thresholds
yet. See [the measurement contract and usage](measurement/README.md).

## Check

```sh
zig build test
python3 tests/pty_smoke.py
zig fmt --check build.zig src measurement
```

The Python script uses only Python's standard library and drives the built binary
through a pseudo-terminal. Python is needed only for these integration tests.
Tests cover editing, visual selections, yank and paste, UTF-8, CRLF, save
conflicts, directory ordering, file navigation and looping, workspace writes,
resizing, and terminal restoration. Use
`zig build -Doptimize=ReleaseSafe` for a release build.
