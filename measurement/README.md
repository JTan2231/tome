# File readiness measurement harness

This area measures one file request through the same `Workspace.ensure` boundary
the editor uses. It has no dependency on the editor, renderer, or terminal.

```sh
zig build measure -Doptimize=ReleaseSafe -- path/to/file
```

The command performs one request and prints one JSON line. It does not run a
benchmark suite, generate fixtures, repeat requests, calculate statistics, or
enforce performance thresholds.

## Boundary

Timing starts before the application buffer-cache lookup. It finishes when the
complete requested file is available, with the buffer initialized, its line count
prepared, and synchronous cache eviction complete. The interval includes file
opening, reading, and required allocation. Directory discovery and path selection
happen before timing; JSON formatting and output happen afterwards.

This is **per-file readiness**, not readiness of the entire viewport. Viewport
traversal, cursor positioning, display-width calculation, terminal-sequence
generation, and terminal output are excluded. Nothing is rendered.

## Samples and reuse

`file_ready.measure(workspace, index)` measures one valid workspace entry and
returns a `Sample`. The caller owns the workspace and chooses its request order
and lifetime. Reusing that workspace permits resident-cache requests; a fresh
workspace begins with no resident buffers. Measurement does not clear caches or
change which files the workspace protects from eviction.

- `elapsed_ns`: monotonic elapsed time in nanoseconds, including I/O waiting.
- `index` (`file_index` in JSON): entry index in this workspace snapshot.
- `cache`: `miss` for a load attempt, `hit` for a resident buffer, or
  `cached_error` for a previously remembered failure.
- `byte_count`: content bytes on success, including zero for empty files; `null`
  on failure. This is not the number of physical disk bytes read.
- `is_new`: distinguishes a new empty document from an existing empty file;
  `null` on failure. Opening a missing file does not create it on disk.
- `outcome`: `ready` or `failed`. The API's failed case carries the file error;
  JSON includes its name as `error_name` (otherwise `null`).

File failures are recorded as samples, and the command exits unsuccessfully after
printing them. Setup or clock failures stop the command with an error on stderr;
they are not readiness samples. An unsuccessful request is never a fast success.
The sample contains no path, file contents, or borrowed document pointer.

Application-cache misses can be served by the operating system's file cache.
Neither a new workspace nor restarting the command establishes a cold disk read.
Record the build revision, optimization mode, machine, fixture identity, and cache
conditions alongside samples when establishing baselines later.

The tests verify outcomes and readiness metadata, with no timing thresholds.
