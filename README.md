# tome

A small terminal text editor written from scratch in Zig. No package dependencies,
terminal library, curses, or mouse support. It uses Zig's standard library and OS
interfaces, with escape sequences targeting Ghostty.

## Install

Use **Zig 0.15.2**. On macOS, Homebrew's `zig@0.15` includes the linker fix needed
for recent Apple SDKs:

```sh
brew install zig@0.15
export PATH="$(brew --prefix zig@0.15)/bin:$PATH"
```

From the checkout, run `./install.sh` to build and install `tome` in
`~/.local/bin`. If that directory is missing from your `PATH`, add the following
line to your shell startup file and open a new terminal.

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Build and run

```sh
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
each group (case-sensitive byte order). A blank row separates file contents. Line
numbers appear in the left gutter and start at 1 for each file. The bottom
status margin shows the file under the cursor. The sequence loops in
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
| `a` | Enter insert after the current character, staying on the same line |
| `Escape` | Return to normal, cancel a selection, pending operator, or command entry |
| `h` `j` `k` `l` | Left, down, up, right in normal or visual |
| Arrow keys | Move in any mode |
| Ctrl+Left / Ctrl+Right | Move by words |
| Page Up / Page Down or Shift+Up / Shift+Down | Scroll by a display of content |
| `0` / `$` | Start / end of line in normal or visual |
| Home / End | Start / end of line in any mode |
| `gg` / `G` | First / last line of the file; repeat at that boundary to reach the previous / next file |
| `u` / `r` | Undo / redo in normal mode |
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
| Text / Enter / Tab | Insert text / newline with copied indentation / indent using the file's style |
| Backspace / Delete | Delete before / at the cursor in insert |
| Ctrl+W | Delete the previous word in insert mode, command entry, or search |
| `:` | Enter an editor command from normal |
| `/` | Enter a forward literal search in normal or visual mode; Enter starts it |
| `n` | Find the next occurrence of the last search from the cursor |
| `Space f` | Open the file picker and filter by path |
| `Space g` | Open the search picker and list matches across the workspace |

Visual selections include the character under the cursor. Press the same visual
key again to cancel, or the other one to switch between characters and lines.
The supported operator motions are `h`, `j`, `k`, `l`, `0`, `$`, `gg`, `G`, arrows,
Ctrl+Left/Right, Home, and End. Vertical motions operate on whole lines. For
example, `y$` yanks to the end of the line and `dj` deletes the current and next
lines. Visual selections and operator motions stay within the current file.
Yanked text can be pasted into another file after navigating there.

`gg` and `G` land on the first nonblank character of the first or last line.
In normal mode, using either while already on its boundary line jumps to the
same boundary of the neighboring file, following the usual browsing order and
looping rules. In visual mode and operator motions, these jumps stay in the
current file.

Undo history belongs to each file and lasts for the editor session, including
after saving or browsing other files. An insert session is one undo step; moving
the cursor starts a new step for subsequent typing. A bracketed paste is its own
step. Deleting or pasting in normal or visual mode is one step per action.
A new edit after undo discards redo history.
Undoing or redoing to the saved version clears the unsaved marker.

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
mode. Numeric counts, block selections, named registers, regular-expression
search, and configuration are not implemented. The cursor denotes an insertion
position, including after the last character of a line; horizontal movement can
cross line boundaries. This differs from Vim's normal-mode cursor semantics.

Search is literal and case-sensitive, with UTF-8 prompt input and a maximum query
length of 1,024 bytes. An empty `/` prompt followed by Enter repeats the previous
query. Normal-mode search follows the workspace's browsing order, starting after
the cursor and wrapping once; visual-mode search stays within the current file
and extends the selection. A sole occurrence at the cursor is found on wrapping.
Insert mode treats `/` and `n` as text.

The current view remains usable while searching. Escape, manual movement,
editing, or another command cancels a pending jump; repeated `n` while searching
coalesces into the current request. A new query replaces the old one. Matches use
resident text, including unsaved edits, and stream unloaded files from disk.
Search pauses at the next match without collecting every occurrence. A complete
pass with no match reports `Pattern not found`; skipped unreadable, changing, or
oversized files are reported as incomplete coverage. The startup file catalog
and existing 64 MiB file limit apply to search too.

In normal mode, `Space` waits for one key. `f` lists browsable workspace paths;
type to filter by substring, ignoring ASCII case. `g` starts with an empty list;
type a literal, case-sensitive query to search the workspace, including unsaved
edits. Matches appear as `path:line:column` and append as the search runs without
moving the selection. Changing the query starts a fresh list.

In either picker, use Up/Down, Page Up/Page Down (or Shift+Up/Down), or Home/End
to move the selection. Ctrl+P/N moves one row and Ctrl+U/D moves half a page.
Enter jumps to the selected file's start or the selected match. Escape returns
to the editor at the original position.

## Behavior and limits

- Zig (`.zig`, `.zon`) and C (`.c`, `.h`) get syntax colors from built-in
  scanners. Highlighting reads the current buffer, including unsaved edits,
  and runs in the background. Existing colors stay visible through edits while
  the scanner checks for changed ranges. Highlighting is limited to buffers up
  to 1 MiB and 65,536 colored ranges per file. No language tools are needed at
  runtime. The default palette is compiled from `src/syntax_theme.json` using
  the ANSI color subset of Tree-sitter's theme format.
- Vertical and horizontal scrolling follow the cursor; lines do not wrap.
- Discovery records file paths, without reading every file into a buffer. Contents
  load as they approach the viewport. Clean buffers and their syntax ranges use
  a cache limited to eight files or 8 MiB, with the active, currently requested,
  and visible files protected.
  A viewport spanning many or large files can exceed this budget. Unsaved
  buffers and files with undo history stay in memory for the session, so their
  size can exceed this cache budget. Undo keeps a full buffer snapshot per step;
  its memory use grows with file size and edit count.
- Interactive frames request missing content asynchronously and can show blank
  filler rows until it is ready. Search scans use separate, bounded 64 KiB chunks
  and do not admit files, change cache recency, or evict editor buffers. Only the
  chosen destination is prepared as an editor document, off the input thread.
  The worker also prepares sparse display positions for the matched line, so
  redrawing a match far into a long line does not walk its entire prefix.
  Resident text reaches the search worker through bounded, revision-checked
  copies; stale results cannot overwrite edits or perform a canceled jump.
  Initial file opening and explicit ordinary navigation retain their synchronous
  loading behavior. Disk bandwidth and the OS file cache are shared with search.
- The file list is a snapshot taken at startup. Discovery matches `.gitignore`
  rules from the workspace root and its subdirectories case-sensitively,
  regardless of Git tracking status. Hidden regular files are eligible.
  Discovery skips `.git` directories and symlinks. Unreadable or oversized
  neighbors are skipped when browsing. An explicitly requested file bypasses
  ignore rules and reports an open error if it cannot be loaded.
- Files retain their bytes, including whether they have a final newline. Enter
  uses the first newline's LF or CRLF style and copies the current line's
  leading whitespace. Copied indentation on an untouched blank line is removed
  when you leave the line or press Escape. New files use LF.
- Tab defaults to four-space stops. On open, Tome samples leading whitespace to
  detect whether the file uses literal tabs or a different number of spaces.
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

Interactive rendering uses `Workspace.request` and `pollRequested` for background
preparation and main-thread publication; the synchronous `ensure` boundary remains
available to explicit navigation and measurement. Search has one cancellable
worker with a bounded mailbox, independent of the viewport loader. It reads
versioned resident chunks or streams disk files, returning one location and, for
an unloaded destination, a prepared document. Workspace ownership and cache
admission remain on the editor thread. Line counts are maintained during edits.

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

Run generated benchmark scenarios with Python 3.10 or later:

```sh
zig build benchmark -Doptimize=ReleaseSafe -- --repetitions 30
```

The suite covers file sizes through 64 MiB, extreme line lengths and counts,
newline and UTF-8 variants, file-limit boundaries, and cache pressure. Inputs are
generated in temporary directories and deleted after each scenario. It prints
median/minimum/maximum timings and retains samples and reproducibility metadata
in ignored `measurement/results/*.jsonl` files. There are no performance
thresholds. See [the measurement contract and usage](measurement/README.md).

Measure scrolling through a real repository with the editor's Page Down and
frame-generation code, without opening a terminal:

```sh
zig build benchmark-scroll -Doptimize=ReleaseSafe -- ~/swift/suwa
```

The default traverses the workspace once; `--steps 1000` sets a fixed load.
Results include scroll latency distributions, file coverage, and per-file byte,
line-count, and line-size statistics. See the
[scroll measurement boundary and options](measurement/README.md#repository-scroll-benchmark).

Measure literal search through the first result frame, with generated inputs at
known byte distances and controlled editor-buffer residency:

```sh
zig build benchmark-search -Doptimize=ReleaseSafe -- --repetitions 30
```

The suite reports median, p95, minimum, and maximum latency for visible and
offscreen hits, loaded and unloaded destinations, many-file traversal, wrapping,
full misses, and destination size/line shape. It measures search completion and
frame generation without terminal display or interaction-responsiveness metrics.
See the [search measurement boundary and scenarios](measurement/README.md#search-benchmark).

## Check

```sh
zig build test
zig build test-benchmark
zig build test-scroll
zig build test-search
zig fmt --check build.zig src measurement
```

The Python scripts use only the standard library. The benchmark suite and its
tests require Python 3.10 or later. Python is not needed to build or run the
editor. Use `zig build -Doptimize=ReleaseSafe` for a release build.
