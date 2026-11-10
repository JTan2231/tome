# Performance measurement harness

The file-readiness harness measures one file request through the same
`Workspace.ensure` boundary the editor uses. It has no dependency on the editor,
renderer, or terminal. The [repository scroll benchmark](#repository-scroll-benchmark)
also exercises the editor's navigation and frame generation under sequential load.

```sh
zig build measure -Doptimize=ReleaseSafe -- path/to/file
```

The command performs one request and prints one JSON line. It does not run a
benchmark suite. For generated scenarios, use the separate `benchmark` command
described below. Neither command enforces performance thresholds.

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

File failures are recorded as samples, and the single-file `measure` command exits
unsuccessfully after printing them. Setup or clock failures stop the command with
an error on stderr; they are not readiness samples. An unsuccessful request is
never a fast success. The reusable sample contains no path, file contents, or
borrowed document pointer.

Application-cache misses can be served by the operating system's file cache.
Neither a new workspace nor restarting the command establishes a cold disk read.
Record the build revision, optimization mode, machine, fixture identity, and cache
conditions alongside samples when establishing baselines later.

## Generated benchmark suite

Requires Python 3.10 or later, using only the standard library:

```sh
zig build benchmark -Doptimize=ReleaseSafe -- --repetitions 30
zig build benchmark -Doptimize=ReleaseSafe -- --list
zig build benchmark -Doptimize=ReleaseSafe -- --scenario shape/ --scenario cache/
```

The default is 30 measured target requests per scenario and request pattern.
`--scenario PREFIX` selects names by prefix and can be repeated; `--list` lists
the selected scenarios without generating inputs or results. The runner prints
median, minimum, and maximum elapsed milliseconds for each scenario/pattern.
Very short requests can reach the clock's resolution, including zero-valued
samples. Treat those as below useful single-request timing precision, not free
operations; the suite does not subtract timer overhead.

`fixtures.py` generates deterministic files from versioned recipes. Each recipe
specifies an exact total byte count, ordinary line content length in bytes
excluding LF/CRLF, newline style, final-newline choice, and ASCII or UTF-8 content.
The remainder line can differ in length to meet the exact size. UTF-8 content
uses valid scalars with ASCII padding where necessary. Metadata records the
recipe, generator version, SHA-256 digest, actual byte and newline counts,
longest line in content bytes, and final-newline presence. Line count follows
Tome's convention: one plus the number of LF bytes, including one line for an
empty document. A missing-file scenario records an absent path instead of
creating a file.

The named families keep size and shape comparisons separate:

| Family | Inputs |
| --- | --- |
| `size/` | Roughly 80-byte lines at 64 KiB, 1, 8, 32, and 64 MiB |
| `shape/` | 8 MiB as one line, 4 KiB lines, one-byte lines, or empty lines; compare with `size/8MiB` |
| `outlier/` | 8 MiB with a 4 MiB line near the beginning, middle, or end |
| `variant/` | 8 MiB with CRLF, no final newline, or multibyte UTF-8 |
| `boundary/` | Existing empty and missing files, and 64 MiB minus/plus one byte; the exact limit is `size/64MiB` |
| `cache/` | 7/8/9 small files, or two files totaling just below/at/above the 8 MiB budget |

Each scenario gets its own system temporary directory, deleted after its request
patterns finish. Cleanup also runs on failures, Ctrl-C, and handled SIGTERM;
uncatchable termination such as SIGKILL cannot run cleanup. There is no option to
retain inputs. Generation and workspace discovery remain outside the measured
interval. Generation can warm the OS file cache, which is recorded as
uncontrolled; these results must not be described as cold disk reads.

`benchmark.py` drives the Zig `tome-bench` worker through the existing measurement
boundary. Non-cache scenarios use `fresh` and `repeat`; cache scenarios use
`pressure`:

| Pattern | Request sequence |
| --- | --- |
| `fresh` | A new workspace for every target request; expect an application-cache miss |
| `repeat` | Prime once, then request the target repeatedly in the same workspace; expect hits, or remembered failures |
| `pressure` | In a new workspace for each repetition, prime the target, request all other files, then revisit the target |

The worker leaves `active_index` null, so pressure scenarios protect only the
currently requested file through the normal production policy. The runner checks
the reported cache state, outcome, size, and prepared line count against each
scenario's expectations. A changed contract or unexpected failure makes the run
fail rather than contributing a misleading success timing. Oversized-file
rejections and remembered errors have separate summaries from ready requests.

No warm-up samples are discarded. Prime and intervening pressure requests are
retained in the raw results but excluded from the target-request summaries.
Timing still measures only complete file readiness; editing, display widths,
rendering, and terminal output remain excluded.

## Benchmark results

By default, results go to `measurement/results/<UTC timestamp>.jsonl`, ignored by
Git. `--output PATH` chooses another destination; the runner creates a new file
and refuses to overwrite an existing one. Only results are retained, not inputs.

The JSONL stream contains:

- `run`: suite/generator versions, revision and working-tree state, machine,
  repetition count, and cache/storage conditions.
- `scenario`: fixture recipes and actual metadata, expected errors, and patterns.
- `worker`: the compiled optimization mode, Zig version, target OS/architecture,
  and production file/cache limits for each worker invocation.
- `sample`: every request, with scenario, pattern, iteration, role, filename,
  readiness fields, prepared line count, and validation results.
- `summary`: validated target samples grouped by scenario/pattern/cache/outcome,
  with sample count and median/minimum/maximum nanoseconds.
- `run_end`: `complete` or `failed`, with an error for failed runs. An interrupted
  output without a completing record is not a completed benchmark.

Run `zig build test` for the Zig tests and `zig build test-benchmark` for fixture
and orchestration checks. Tests verify outcomes and metadata without timing
thresholds.

## Repository scroll benchmark

Point the headless runner at an existing folder (Python 3.10 or later):

```sh
zig build benchmark-scroll -Doptimize=ReleaseSafe -- ~/swift/suwa
zig build benchmark-scroll -Doptimize=ReleaseSafe -- ~/swift/suwa --steps 1000
zig build benchmark-scroll -Doptimize=ReleaseSafe -- ~/swift/suwa --rows 50 --cols 160
```

The default sends Page Down until the first wrap or the end of a short workspace.
The final event includes the wrap into earlier content, or the stationary event
that detects the end. `--steps N` sends exactly N events, including repeated
circuits when applicable. An empty or entirely unreadable workspace has zero
events in the default mode. The viewport defaults to 40 rows by 120 columns;
the editor reserves two rows for status and commands.

The worker uses production directory discovery, `Editor.initWorkspace`,
`Editor.handle(.page_down)`, and `Editor.renderFrame`. The interactive terminal
loop calls the same frame method. Each scroll interval includes navigation,
lazy file loading, cache eviction, viewport traversal, width calculation, and
ANSI frame generation. It ends before terminal output. No terminal opens and
no input file is edited or saved. Unreadable and oversized files follow the
editor's skip behavior and appear as failed files in the report.

Discovery and startup-to-first-frame have separate timings. Every subsequent
sample covers one key plus one complete frame. Events run sequentially without
human pauses. JSON serialization, result writing, and inventory work are outside
these intervals; reporting between events still adds process overhead. The
worker's wall time includes process startup, discovery, and reporting, while
the scroll total sums only the measured event intervals. This measures editor
work under sustained scrolling, not end-to-end terminal latency or displayed FPS.

The run starts with a fresh application workspace and retains the normal cache
policy throughout. No warm-up is discarded. The operating system's file cache
is uncontrolled. Repeated invocations may benefit from previous reads, including
the previous run's inventory. Use matching builds and viewport dimensions when
comparing runs.

Discovery includes hidden and ignored regular files, skips `.git` directories
and symlinks, and uses the editor's directories-first ordering. In particular,
Suwa's `.local` databases and generated data are part of this workload. A fixed
step count can finish before reaching source files. Coverage reports the number
of files ever loaded, failed, and unvisited. Loaded includes viewport prefetch;
it does not mean the cursor visited every line or that the buffer remains cached.

### Statistics and results

The console reports total, median, p95 (nearest rank), and maximum elapsed time,
plus the number of events exceeding 16.67 ms. This reference interval is a useful
way to count slow events; it is not an enforced performance threshold. The report
also shows the largest files and slowest events. An event's destination file is
context, not attribution: that event can cross and load several files.

After the worker exits, the runner reads the discovered files to collect:

- Per-file bytes, line count, maximum and mean line length in content bytes,
  SHA-256, and modification time.
- Per-file and aggregate line-size counts: empty, 1–80, 81–256, 257–1,024,
  1,025–4,096, 4,097–65,536, and over 65,536 content bytes.
- Repository byte and line totals, file coverage, load errors, and files for
  which inventory could not collect line statistics.

Line count is one plus the number of LF bytes, including the trailing empty
line after a final LF and one line for an empty file. Line lengths exclude LF
and its preceding CR; they retain other bytes and are not Unicode character or
display-column counts. Binary files follow these same byte rules. Files larger
than the production 64 MiB limit retain their size but have no line statistics.
Statistics are a post-run snapshot, separate from the measured workload. The
report flags files that change during inventory or whose line count differs
from the last count observed during scrolling. It cannot detect every change
made by another process during a run.

Results default to ignored `measurement/results/scroll-<UTC>.jsonl` files.
`--output PATH` selects a new result file; existing files are never overwritten.
Results must be outside the target tree so that discovery does not include the
growing report. When the default directory is inside the target, results use
`tome-measurements` in the system temporary directory instead.

JSONL records include `run` (revision, machine, workload), `worker` (build and
discovery), `sample` (startup or scroll timing and cursor position),
`catalog_file` (the worker's discovered paths and observed line counts),
`complete` (worker coverage and stop reason), `worker_wall`, `summary`,
`slow_frame`, `file` (post-run per-file statistics), and `repository_summary`.
The final `run_end` must have `status: complete` for a completed report. Setup,
worker, or reporting failures produce a failed run and preserve available raw
records. Expected file skips are reported separately from runner failures.

Run `zig build test-scroll` for end-to-end traversal, statistics, read-only input,
and result-path checks. The runner's Zig correctness tests are part of
`zig build test`. Neither test target enforces timing thresholds.
