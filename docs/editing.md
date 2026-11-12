# Edit text

Tome edits text in the file under the cursor. The editor tracks the current
mode and selection, keeps undo history per file, and shares one register
across the session. Check the status row to see which file and mode are active.
[Read the viewport](terminal.md#read-the-viewport)

## Change modes

Tome starts in normal mode. Use insert mode to type and visual mode to select
text.

| Key | Effect |
| --- | --- |
| `i` | Enter insert mode at the cursor from normal mode. |
| `a` | Enter insert mode after the current character from normal mode. At the end of a line, stay on that line. |
| `v` | Start a character selection from normal mode. |
| `V` (`Shift+V`) | Start a whole-line selection from normal mode. |
| `Escape` | Return to normal mode or cancel the current selection, pending operator, or prompt. |

Tome supports character and whole-line selections. Numeric counts, block
selections, named registers, and editor configuration are unavailable.

## Enter a command

Start in normal or visual mode. Tome accepts write and quit commands.
[Save and recovery](workspace.md#save-and-recovery)

1. Press `:` to open the command prompt. In visual mode, this ends the selection
   and returns to normal mode.
2. Type the command after `:`. Use `Backspace` to delete the previous character
   or `Ctrl+W` to delete the previous word. The prompt accepts up to 128
   printable ASCII bytes.
3. Press `Enter` to submit the command. If Tome stays open, check the last row
   for the result.

Press `Escape` to close the prompt without submitting a command. For text
queries and picker controls, see [Search and pickers](search.md).

## Move the cursor

| Key | Motion |
| --- | --- |
| `h`, `j`, `k`, `l` | Move left, down, up, or right in normal or visual mode. |
| `Left`, `Down`, `Up`, `Right` | Move in the indicated direction in any editing mode. |
| `Ctrl+Left`, `Ctrl+Right` | Move by words. |
| `Page Up` or `Shift+Up`, `Page Down` or `Shift+Down` | Move up or down by one viewport of content. |
| `0`, `$` | Move to the start or end of the line in normal or visual mode. |
| `Home`, `End` | Move to the start or end of the line in any editing mode. |
| `gg`, `G` | Move to the first nonblank position on the first or last line in normal or visual mode. |

The cursor marks an insertion position. It can sit after the last character on
a line. Horizontal movement can cross line and file boundaries. Moving or
deleting one character steps over a UTF-8 scalar, a CRLF pair, or a single
malformed UTF-8 byte.

In normal mode, press `gg` on the first line or `G` on the last line to move to
the same boundary in the previous or next file. File changes follow catalog
order and wrap according to the viewport size. Visual selections and operator
motions stay in the current file.
[Workspace order](workspace.md#startup-and-discovery), [Viewport wrap rules](terminal.md#read-the-viewport)

Page motions use the height of the content area and count each file separator
as one row. Tome keeps the cursor at the same screen row when enough content
remains.

## Select and change text

Start in normal mode to select text.

1. Press `v` to select characters or `V` to select whole lines. The selection
   includes the character or line under the cursor.
2. Move the cursor to extend the selection. Press `o` to move to the other end.
3. Apply an operation from the visual mode column below.

To cancel the selection, press `Escape` or the key that started it. Press the
other visual key to switch between character and whole-line selection.

| Keys | Normal mode | Visual mode |
| --- | --- | --- |
| `y` | Wait for a motion. Press `yy` to yank the current line. | Yank the selection. |
| `Y` | Yank the current line. | Yank all lines touched by the selection. |
| `d` | Wait for a motion. Press `dd` to delete the current line. | Delete the selection. |
| `x` | Delete the character at the cursor within the current line. | Delete the selection. |
| `c` | Wait for a motion. Press `cc` to change the current line. | Change the selection. |
| `D`, `C` | Delete or change through the end of the line. | Delete or change all lines touched by the selection. |
| `p`, `P` | Paste after or before the cursor. For whole lines, paste below or above the current line. | Replace the selection with the text in the register. |
| `Delete` | — | Delete the selection. |

In normal mode, press `y`, `d`, or `c` and then use a motion to set the range.
All motions in the cursor table work with these operators. `j`, `k`, `Up`,
`Down`, `gg`, and `G` select whole lines. For example, `y$` yanks to the end of
the line and `dj` deletes the current and next lines.

A change deletes the range and enters insert mode. A yank copies the range and
reports the number of bytes copied. In normal and visual mode, yank, delete,
and change store the range in the session's register. The system clipboard is
separate.

Pasting over a visual selection preserves the register for another replacement.
If the register has no contents yet, Tome reports `Nothing yanked` and leaves
the buffer as it was. Yank or delete text before trying again.

## Insert text

Type in insert mode. Use `Backspace` to delete before the cursor and `Delete`
to delete at the cursor. Use `Ctrl+W` to delete the previous word. At the start
of a line after the first, `Ctrl+W` joins it to the previous line.

Press `Enter` to insert a newline with the current line's indentation. Tome
uses the first newline in the file to choose LF or CRLF. New files and files
with no newline use LF. Tome preserves existing line endings, including a
final newline, unless you edit them. Tome removes copied indentation when you
leave an untouched blank line or press `Escape`.

Press `Tab` to insert a literal tab or spaces to the next indentation stop.
When Tome opens a file, it samples leading whitespace on nonblank lines in
the first 64 KiB. It detects literal tabs or space indentation widths from 1
to 16 columns. It uses stops every four spaces when it detects no style.

Tome inserts text from terminal bracketed paste only in insert mode. It
converts pasted line endings to the file's style. It keeps tabs and removes
ASCII control bytes apart from tabs and line endings.
[Search and pickers](search.md) covers paste into picker queries.

## Undo and redo

In normal mode, press `u` to undo or `r` to redo an edit in the current file.
Each file keeps its history for the session, including after saving or moving
to another file. When you reach the start or end of the history, Tome reports
`Nothing to undo` or `Nothing to redo`.

Typing in insert mode is one undo step until you move, press `Escape`, or
paste. A change operator groups its deletion with typing in that step. A
bracketed paste has its own step. Deleting or pasting in normal or visual mode
takes one step per action.

A new edit after undo discards the edits you could redo. Undo or redo to the
saved version to clear the `[+]` marker. Each step keeps a full buffer
snapshot, so memory use increases with the file size and number of steps.
