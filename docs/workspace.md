# Workspace and storage

A workspace lets you browse and edit files in a directory tree. It owns the
startup catalog of file paths and the loaded documents. The editor thread
controls which documents enter or leave the cache.

## Startup and discovery

Without a path argument, Tome uses the current directory as the workspace root.
A directory argument selects that directory as the root. A file argument selects
the initial document and keeps the current directory as the root. If the file
is outside the current directory, Tome uses its parent directory as the root.
[Open a workspace](installation.md#open-a-workspace)

Tome visits each directory's subdirectories before its files. It sorts names in
each group by case-sensitive byte order. Tome records paths without loading
document buffers. The catalog can include hidden regular files. Discovery
skips `.git` directories, symlinks, and other special files. Restart Tome to
refresh the catalog.

Tome applies `.gitignore` rules from the workspace root and its subdirectories.
Rules match case-sensitively and apply to tracked and untracked files. The last
matching rule in the nearest applicable `.gitignore` wins. Tome skips excluded
directories, so a rule inside an excluded directory cannot restore its contents.
Tome reads these files directly without consulting Git's index or configuration.
It skips any `.gitignore` file that it cannot read or that exceeds 100 MiB.

A leading or internal `/` anchors the pattern to the `.gitignore` file's
directory. Without either, the pattern matches names at any level below that
directory. A trailing `/` limits the rule to directories. Start a rule with `!`
to negate it. Patterns support `*`, `?`, `**`, bracket expressions, and escapes.

Tome includes an explicit file argument even if ignore rules exclude it. If the
path is a symlink, Tome opens its target. For a missing file, the parent directory
must already exist. Tome opens an empty document and creates the file when you
save it. If Tome cannot open an explicit path, it prints `tome: <error>` and
exits. For example, a dangling symlink produces `tome: DanglingSymlink`.

Tome skips unreadable subdirectories during discovery. While browsing, it skips
files it cannot load. If no files are readable, the browser displays
`No readable files in this workspace`.

## Document readiness

`Workspace.ensure` returns one ready document. It prepares the buffer, newline
style, indentation style, and line count before trimming the cache. Callers borrow
the document until the workspace evicts it or shuts down. Explicit opening and
ordinary navigation use this operation. The file readiness harness times it.
[Performance measurement](measurement.md)

During interactive rendering, `Workspace.request` returns a resident document
or requests background preparation. The loader handles one file at a time and
keeps only the latest waiting request. A frame can show filler rows while the
loader prepares content. The worker owns the prepared document until the editor
adopts it. `Workspace.pollRequested` adopts it only if the request remains active
and the catalog entry is still unloaded at the expected revision.

Tome remembers file access and read errors for the session. To retry a file,
fix the problem on disk and restart Tome. Save any open edits before restarting.

Tome keeps the last known line count when it evicts a document. A later load
refreshes that count from disk. A buffer has one logical line plus one per LF
byte, including an empty line after a final LF. Edits update this count.

## Cache and file limits

Tome can open a regular file up to 64 MiB. It keeps each loaded file in
an in-memory byte array. An unloaded file takes up catalog space only.

The clean cache has a budget of eight files and 8 MiB total. The byte budget
counts allocated capacity for buffers and syntax ranges. When the cache exceeds
either limit, Tome evicts the least recently used document that it can evict.

Tome protects the active file, the current request, and files the viewport uses
from eviction. These files can exceed the cache budget. New documents, documents
with unsaved edits, and documents with undo history stay resident outside that
budget. [Undo and redo](editing.md#undo-and-redo)

## Save and recovery

Start in normal mode.

1. Type `:wt` to write the file under the cursor, even if it has no edits.
   To save all new or edited documents, type `:w` or `:write`.
2. Press `Enter` to run the command.
3. Check the message. `:wt` reports `Written <path>` on success. A workspace
   write reports `Written <count> files` when all eligible writes succeed.

If `:wt` fails, Tome reports `Save failed: <error>: <path>` and keeps your edits.
If no file is open, it reports `No file under cursor`.

On a workspace write, Tome attempts to save each new document and each document
with unsaved edits. If any write fails, Tome reports the first error and the
totals in `Save failed: <error>: <path> (<written> written, <failed> failed>`.
Successful files stay saved. Tome keeps edits for failed files in memory. Fix
the reported problem before retrying the write.

Tome checks the destination before writing the buffer's exact bytes to a
temporary sibling file. It syncs the temporary file, checks the destination
again, and then replaces it atomically. Each check compares the existing file's
inode, size, modification time, and change time with the saved version. For a
new file, Tome checks that the destination is still absent. If a check detects
an outside change, Tome reports `FileChangedOnDisk` and keeps your edits.
Preserve those edits outside Tome before reopening the changed file.

Tome replaces each destination independently. Another writer can still change
the destination after the metadata check.

Saving requires permission to replace the destination in its directory. For an
existing file, Tome also requires read and write access. On macOS and Linux,
Tome retains the file's basic permission bits. Replacement creates a new file
identity. The new file loses hard-link sharing, ownership, ACLs, and extended
attributes from the original. If Tome opened a symlink, saving updates the
resolved target.

In normal mode, submit `:q` or `:quit` to close the editor. If any file has
unsaved edits, Tome stays open and reports `Unsaved changes; use :w or :q!`.
Submit `:q!` or `:quit!` to close the editor and discard unsaved edits. Tome
provides no autosave or crash recovery.
