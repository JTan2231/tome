# Source layout

Tome is a terminal text editor written in Zig. You can browse a directory tree
as a single stream and edit files without leaving the stream. Tome uses Zig's
standard library to talk to the operating system and terminal.

## System references and source files

| Reference | Source files |
| --- | --- |
| [Install and run Tome](installation.md) | Startup in [`main.zig`](../src/main.zig), build targets in [`build.zig`](../build.zig), installation in [`install.sh`](../install.sh) |
| [Edit text](editing.md) | Modes, selections, and commands in [`editor.zig`](../src/editor.zig); text in [`buffer.zig`](../src/content/buffer.zig); indentation in [`indentation.zig`](../src/content/indentation.zig); undo in [`history.zig`](../src/content/history.zig) |
| [Workspace and storage](workspace.md) | Catalog and cache in [`workspace.zig`](../src/content/workspace.zig); ignore rules in [`gitignore.zig`](../src/content/gitignore.zig) and [`wildmatch.zig`](../src/content/wildmatch.zig); loading in [`loader.zig`](../src/content/loader.zig); file access in [`storage.zig`](../src/content/storage.zig) |
| [Search and pickers](search.md) | Next-match search in [`search.zig`](../src/content/search.zig), workspace text search in [`workspace_search.zig`](../src/content/workspace_search.zig), picker controls in [`picker.zig`](../src/picker.zig) |
| [Terminal and display](terminal.md) | Frames in [`editor.zig`](../src/editor.zig), row traversal in [`stream.zig`](../src/stream.zig), display cells in [`display.zig`](../src/display.zig), terminal I/O in [`terminal.zig`](../src/terminal.zig), syntax colors in [`src/content/highlight/`](../src/content/highlight) and [`syntax_theme.zig`](../src/syntax_theme.zig) |
| [Performance measurement](measurement.md) | File readiness, generated fixtures, scrolling, and search timing in [`measurement/`](../measurement) |

## How the systems fit together

At startup, Tome selects the workspace and prepares the initial view. The
terminal passes keys and text to the editor. The editor interprets each event
in the current mode and builds a frame from workspace rows. The terminal
displays that frame.

The [content module](../src/content/root.zig) manages the workspace catalog,
buffers, and file storage. Background workers prepare documents, search text,
and find syntax colors. The editor thread decides which documents enter the
cache and whether worker results still apply to the current view.

The file readiness harness requests documents directly from the workspace.
The scroll and search benchmarks send input to the editor and build frames
without opening a terminal. See [Performance measurement](measurement.md) for
what each timer includes.

## Check changes

Start in the checkout with the [required Zig version](installation.md). Choose
the checks that cover the change, following the [test rules](../AGENTS.md#testing).

| Check | Command |
| --- | --- |
| Full Zig test suite | `zig build test` |
| File readiness benchmark fixtures and validation | `zig build test-benchmark` |
| Repository scroll benchmark | `zig build test-scroll` |
| Search scenarios and measurement validation | `zig build test-search` |
| Zig formatting for a changed file, for example `src/editor.zig` | `zig fmt --check src/editor.zig` |
