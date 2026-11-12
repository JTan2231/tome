# Search and pickers

Forward search jumps to the next match and remembers your last query. The file
picker filters workspace paths. The search picker lists workspace text matches
for its current query. Both text searches match literal bytes and are
case-sensitive. Each text query can contain up to 1,024 UTF-8 bytes.

## Find the next match

Start in normal or visual mode with a file open.

1. Press `/` to open the search prompt.
2. Type the text to find. Leave the prompt empty to reuse the last query.
3. Press `Enter` to search. Tome moves the cursor to the next match it finds.

In normal or visual mode, press `n` to repeat the last query from the cursor.
Tome reports `No previous search` if you repeat before entering a query. In
insert mode, `/` and `n` insert text.

At the search prompt, `Backspace` deletes the previous character or closes an
empty prompt. `Ctrl+W` deletes the previous word. If input would exceed the
query limit, Tome keeps the current text and reports `Search is limited to 1024 bytes`.

Search starts after the cursor and wraps through the starting position once.
A sole match at the cursor can appear after a wrap. In normal mode, search
follows workspace browsing order. In visual mode, search stays in the current
file and extends the selection. [Startup and discovery](workspace.md#startup-and-discovery)

Press `Escape` to close the prompt or cancel a pending jump. Moving, editing, or
entering another command also cancels a pending jump. If you press `n` while a
jump is pending, Tome continues the current search. A new query replaces it.

On success, Tome reports `Match` or `Search wrapped`. If the scan skips any
files, Tome adds `(<count> files skipped)`. It can skip unreadable, oversized,
or externally changed files.

If the scan finds no match, the cursor stays in place. A complete pass reports
`Pattern not found`. A pass that skips files reports `Search incomplete: <count> files skipped`.
If the search itself fails, Tome reports `Search failed: <error>`.

## Filter workspace paths

Start in normal mode.

1. Press `Space` then `f` to open the `Files>` picker.
2. Type part of a path to filter the list.
3. Select a file with the [picker keys](#move-and-close-a-picker).
4. Press `Enter` to open the file at its start.

The file picker starts with the browsable entries in the startup catalog. It
includes loaded files and checks read access, file type, and size for unloaded
files. This check does not read file contents. The filter matches any substring
of a workspace path, ignoring ASCII case. Each query accepts up to 1,024 bytes on
macOS or 4,096 bytes on Linux.
[Cache and file limits](workspace.md#cache-and-file-limits)

## List workspace text matches

Start in normal mode.

1. Press `Space` then `g` to open the `Search>` picker with an empty list.
2. Type the text to find. Matches appear as the scan runs.
3. Select a match with the [picker keys](#move-and-close-a-picker).
4. Press `Enter` to jump to the selected match.

Tome lists matches in catalog order and byte order within each file. Each match
shows `path:line:column` with a line number and display column that start at 1.
New matches append without moving the selection. Changing the query starts a
fresh list. [Read the viewport](terminal.md#read-the-viewport)

Tome shows `Searching…` while the scan runs. The picker can skip files it
cannot read. If you expect a match in a file, check that Tome can open it.
If Tome cannot start the search, it reports `Search failed`.

Before jumping, Tome checks the revision of a resident match. For every match,
it checks that the query still starts at the recorded byte offset. If either
check fails, Tome closes the picker, leaves the cursor in place, and reports
`Search match changed: <path>`. Open the search picker again to refresh results.

## Move and close a picker

| Key | Action |
| --- | --- |
| `Up`, `Down`, `Ctrl+P`, `Ctrl+N` | Move one result. |
| `Page Up`, `Page Down`, `Shift+Up`, `Shift+Down` | Move one page. |
| `Ctrl+U`, `Ctrl+D` | Move half a page. |
| `Home`, `End` | Move to the first or last result. |
| `Backspace`, `Ctrl+W` | Delete the previous character or word from the query. |
| `Enter` | Open the selected result. |
| `Escape` | Return to the editor at the original position. |

Both pickers accept bracketed paste as query text. Each picker accepts only
complete UTF-8 characters that fit within its query limit.

Tome displays `No matches` when a filter or completed search returns an empty
list. With no selection, `Enter` leaves the picker open.

When you open a result, Tome closes the picker and makes the file ready before
moving the cursor. If the file fails to load, Tome keeps the original position
and reports `Could not open <path>: <error>`.
[Document readiness](workspace.md#document-readiness)

## Search workers

Both workers scan the startup catalog and apply the workspace file limit to
files on disk. The editor thread owns resident buffers, including unsaved edits.
It supplies copies in chunks of up to 64 KiB and checks their revisions. The
workers read unloaded files in chunks of up to 64 KiB. Scanning leaves cache
membership and recency unchanged. Search shares disk bandwidth and the OS file
cache with the rest of Tome. [Workspace and storage](workspace.md)

The forward search worker stops at the first match and prepares the destination
if it is unloaded. It records display positions so the renderer can draw near a
match deep in a long line. The editor checks the revision and request state
before it accepts the destination and moves the cursor. It retries against
current content if edits or cache changes make a result stale.
[Performance measurement](measurement.md)

The search picker worker publishes up to 1,024 matches per batch. The editor
keeps the accumulated list for the current query. Changing the query or closing
the picker cancels the active scan.
