# Performance measurement

Tome measures file readiness, sequential scrolling, and literal search using
the editor's content and frame code. The measurements record elapsed time
without a terminal. Run the commands from the checkout with the pinned Zig
version. [Set up Zig](installation.md)

## Choose a measurement

| Command | Measurement |
| --- | --- |
| `zig build measure` | One file request through complete buffer readiness |
| `zig build benchmark` | File readiness across generated file shapes, sizes, and cache states |
| `zig build benchmark-scroll` | `Page Down` through a directory, with one generated frame per event |
| `zig build benchmark-search` | Literal search submission through the first result frame |

The benchmarks create fresh workspaces at the points described below. The
operating system manages its own file cache. Fixture generation and earlier
reads can warm it, even for files absent from the workspace cache. The
raw reports include the first sample and any requests that prime the cache.
The benchmarks enforce no performance thresholds. For correctness checks, see
[Check changes](source-layout.md#check-changes).

## Benchmark reports

The benchmarks print summaries and save JSONL reports, with one JSON record
per line. The default directory is `measurement/results/`, which Git ignores.
Each filename includes a UTC timestamp. Use `--output PATH` to choose a new
report path. The benchmarks refuse to overwrite an existing file.

Check that the last record has `type` equal to `run_end` and `status` equal
to `complete`. A failure can leave partial results or a final record with
`status` equal to `failed`. Check the error in the report or on standard
error. To retry, choose a new report path. Use matching builds, machines,
workloads, and cache conditions to compare runs.

## Generated benchmark options

The file readiness and search benchmarks accept these options.

| Option | Effect |
| --- | --- |
| `--list` | List selected scenarios without creating fixtures or a report |
| `--scenario PREFIX` | Select scenarios by name prefix. Repeat the option to select several prefixes. The default selects all scenarios. |
| `--repetitions N` | Collect N samples per search scenario or per file readiness scenario and request pattern. N must be positive. The default is 30. |

## Measure one file

The file's parent directory must exist. Run the command with a file path.
Tome opens a workspace rooted at the parent and writes one JSON line to
standard output.

```sh
zig build measure -Doptimize=ReleaseSafe -- path/to/file
```

Check the sample's `outcome`. An explicitly requested missing file can
produce a `ready` sample with zero bytes and `is_new` set to `true`.
Measuring it leaves the path absent.

The timer starts before the workspace cache lookup and stops when
`Workspace.ensure` returns or fails. The interval includes file loading,
document preparation, and cache eviction. Workspace discovery, viewport
traversal, cursor positioning, display width calculation, frame generation,
and reporting occur outside the interval. For the prepared metadata, see
[Document readiness](workspace.md#document-readiness).

Call `file_ready.measure(workspace, index)` to measure a request in an
existing workspace. Supply a valid catalog index. You retain ownership of the
workspace. The sample holds metrics and the outcome. Reuse the workspace to
measure a cache hit or a remembered load failure. For eviction rules, see
[Cache and file limits](workspace.md#cache-and-file-limits).

| JSON field | Meaning |
| --- | --- |
| `metric` | `file_request_to_ready` |
| `file_index` | Catalog index in this workspace. The Zig sample names it `index`. |
| `elapsed_ns` | Monotonic elapsed time in nanoseconds, including I/O waits |
| `cache` | `hit` for a resident document, `miss` for a load attempt, or `cached_error` for a remembered failure |
| `byte_count` | Buffer length in bytes on success or `null` on failure |
| `is_new` | `true` for a missing file opened as an empty document, `false` for an existing file, or `null` on failure |
| `outcome` | `ready` or `failed` |
| `error_name` | Zig error name on failure or `null` on success |

For a failed file request, `tome-measure` prints the sample and exits with
status 1. Check the sample's `error_name`. If setup or the clock fails, the
command stops without a sample and prints the error to standard error.

## Generated file-readiness benchmark

1. List scenarios and request patterns with `--list`.

   ```sh
   zig build benchmark -Doptimize=ReleaseSafe -- --list
   ```

2. Run the selected scenarios. [Generated benchmark options](#generated-benchmark-options)

   ```sh
   zig build benchmark -Doptimize=ReleaseSafe -- --scenario shape/ --scenario cache/
   ```

3. Check the completion record. The console prints median, minimum, and
   maximum elapsed time in milliseconds. [Benchmark reports](#benchmark-reports)

### File fixtures and request patterns

Each recipe sets total bytes, ordinary line length in content bytes, LF or
CRLF, final newline presence, and ASCII or UTF-8. Content bytes exclude line
endings. The last line can have a different length so the file reaches its
exact size. UTF-8 fixtures use valid scalars and add ASCII padding where
needed. The missing file scenario records an absent path.

Fixture metadata records the recipe, generator version, and SHA-256 digest.
It also records actual byte and newline counts, logical line count, longest
line in content bytes, and final newline presence. For how Tome counts
lines, see [Document readiness](workspace.md#document-readiness).

| Family | Inputs |
| --- | --- |
| `size/` | Roughly 80 bytes per line at 64 KiB, 1 MiB, 8 MiB, 32 MiB, and 64 MiB |
| `shape/` | 8 MiB as one line, 4 KiB lines, one-byte lines, or empty lines. Compare with `size/8MiB`. |
| `outlier/` | 8 MiB with a 4 MiB line near the beginning, middle, or end |
| `variant/` | 8 MiB with CRLF, no final newline, or multibyte UTF-8 |
| `boundary/` | Existing empty and missing files, and one byte below and above 64 MiB. Use `size/64MiB` for the exact limit. |
| `cache/` | Seven, eight, or nine small files, or two files totaling just below, at, or just above 8 MiB |

The benchmark generates each scenario in a temporary directory. It removes
the directory when that scenario ends, including on errors and handled
`SIGINT` or `SIGTERM`. A forced stop such as `SIGKILL` can leave fixtures
behind. Generation and workspace discovery occur outside the timed requests.

The benchmark calls the same file readiness function as the single file
command. It uses `fresh` and `repeat` for file scenarios and `pressure` for
cache scenarios.

| Pattern | Requests |
| --- | --- |
| `fresh` | Open a new workspace for each target request. Expect `miss`. |
| `repeat` | Prime the target once. Request it repeatedly in the same workspace. Expect `hit` or `cached_error`. |
| `pressure` | Open a new workspace for each repetition. Prime the target, request the other files, and revisit the target. |

The pressure pattern has no active file. The workspace protects the current
request from eviction. The benchmark validates cache state, outcome, byte
count, and line count for each request. Unexpected results fail the run.

### File readiness report

The report defaults to `measurement/results/<UTC>.jsonl`. Summaries count only
target requests and group them by scenario, pattern, cache state, and outcome.
Raw samples include prime requests and intervening requests in `pressure`.
A very short request can register zero elapsed nanoseconds at the clock's
resolution. The elapsed time includes timer overhead.

| JSONL record | Contents |
| --- | --- |
| `run` | Suite and generator versions, revision, working tree state, machine, repetitions, and cache and storage conditions |
| `scenario` | Fixture recipes and metadata, expected errors, and request patterns |
| `worker` | Optimization mode, Zig version, target OS and architecture, and production file and cache limits |
| `sample` | Scenario, pattern, iteration, role, filename, readiness fields, prepared line count, and validation |
| `summary` | Validated target request count and median, minimum, and maximum elapsed time in nanoseconds |
| `run_end` | Final status and any failure error |

## Repository scroll benchmark

Use an existing directory as the input. If you set `--output PATH`, choose
a new path outside that directory so discovery excludes the report.

1. Run the benchmark with the directory path. It sends `Page Down` events
   and prints the report path.

   ```sh
   zig build benchmark-scroll -Doptimize=ReleaseSafe -- path/to/repository
   ```

2. Check the completion record. The console prints timing, file coverage,
   and inventory summaries. [Benchmark reports](#benchmark-reports)

By default, the benchmark stops at the first wrap or when `Page Down` leaves
the cursor at the same position. It includes that last event in the timing
samples. An empty or entirely unreadable workspace has zero events in this
mode. Set `--steps N` to send exactly N events, where N is positive. A
workspace that wraps can make repeated circuits.

Set `--rows N` or `--cols N` to change the viewport dimensions. The default
is 40 rows by 120 columns, and the minimum is three rows by two columns.
The viewport includes two rows for status and commands.

### Scroll timing and coverage

The benchmark uses production workspace discovery and editor frames. It times
discovery and startup through the first frame separately. A scroll timer
starts before the editor handles `Page Down` and stops after it generates
the resulting ANSI frame. It includes navigation, file loading, eviction,
viewport traversal, and display width calculation. See
[Frame generation](terminal.md#generate-a-frame).

The worker sends events in sequence without pauses. It opens input files
read-only and leaves syntax highlighting disabled. JSON reporting and file
inventory occur outside the scroll samples. `worker_wall.elapsed_ns` includes
process startup, discovery, measured work, and worker reporting. The
`scroll_to_frame` total sums only the timed scroll samples.

The benchmark uses the production discovery rules. A fixed step count can
end before the benchmark visits all files. Loaded coverage includes files
loaded for the viewport and files later evicted from the cache. The report
counts failed and unvisited files separately. For catalog rules, see
[Workspace discovery](workspace.md#startup-and-discovery).

### Scroll statistics and report

The console shows total seconds and the median, nearest-rank p95, and maximum
in milliseconds. It counts events longer than one sixtieth of a second
(about 16.67 ms). It lists the slowest events and largest files. A sample's
destination file identifies where the cursor stopped. An event can cross
and load several files.

After the worker exits, the benchmark reads the cataloged files and reports
these statistics.

- Per file, it records size in bytes, line count, maximum and mean line length
  in content bytes, SHA-256, and modification time.
- For each file and across the repository, it counts lines of 0, 1–80, 81–256,
  257–1,024, 1,025–4,096, 4,097–65,536, and over 65,536 content bytes.
- For the repository, it totals known file sizes and available line counts.
  It also reports file coverage, load errors, and files without line statistics.

The inventory uses the workspace's LF-based line count. It measures line
length in bytes, excluding the LF and its preceding CR. These rules also
apply to binary files. Files over the 64 MiB production limit contribute
their size without line statistics. The report flags detected changes during
inventory and differences from the line count observed during scrolling. For
how Tome counts lines, see [Document readiness](workspace.md#document-readiness).

The report defaults to `measurement/results/scroll-<UTC>.jsonl`. If that
directory is inside the input tree, the benchmark uses `tome-measurements`
in the system temporary directory. If the fallback is inside the input tree,
set `--output PATH` outside that tree.

| JSONL record | Contents |
| --- | --- |
| `run` | Workload, machine, and revision metadata |
| `worker` | Build, viewport, and discovery metadata |
| `sample` | Startup or scroll timing and cursor position |
| `catalog_file` | Cataloged file path, observed line count, and any load error |
| `complete` | File coverage and stop reason |
| `worker_wall` | Total worker time |
| `summary` | Timing statistics |
| `slow_frame` | One of the slowest scroll samples |
| `file` | Post-run per-file statistics |
| `repository_summary` | Post-run totals |
| `run_end` | Final status and any failure error |

Skips for unreadable or oversized files appear as load errors while the run
continues.

## Search benchmark

1. List the available scenarios with `--list`.

   ```sh
   zig build benchmark-search -Doptimize=ReleaseSafe -- --list
   ```

2. Run the selected scenarios. [Generated benchmark options](#generated-benchmark-options)

   ```sh
   zig build benchmark-search -Doptimize=ReleaseSafe -- --scenario readiness/ --scenario files/
   ```

3. Check the completion record. The console prints median, nearest-rank p95,
   minimum, and maximum milliseconds. [Benchmark reports](#benchmark-reports)

### Search timing and residency

The timer starts just before `Enter` submits a populated `/` prompt. It
stops after search completes and the editor generates the first result frame.
The interval includes destination loading, line and display preparation,
and frame generation. The destination must be ready for a match. Neighboring
files can still show loading filler. A miss produces the frame with
`Pattern not found`. [Literal search](search.md)

The benchmark enables asynchronous viewport loading and leaves syntax
highlighting disabled. It services editor ticks with `Thread.yield` between
ticks. Fixture generation, initial workspace and viewport setup, target
preloading, query entry, validation, and reporting occur outside the interval.
The benchmark measures an editor frame without terminal polling, intermediate
redraws, terminal I/O, screen display, or cancellation timing.

Each sample starts with a fresh workspace and editor. The origin file is
resident in the workspace cache. The benchmark preloads a separate target
only in the designated scenario. It records target residency just before
submission. It checks visibility against the initial frame and verifies both
values against the scenario.

### Search scenarios and distance

Each fixture uses printable ASCII and LF. Ordinary lines have 63 content
bytes before LF. The generator places `TOME_SEARCH_NEEDLE` once at a known
byte offset or omits it for a miss. The viewport is 40 rows by 120 columns.
The benchmark generates each scenario in a temporary directory and removes
it when the scenario ends. Reports stay outside the fixture workspace.

| Family | Inputs |
| --- | --- |
| `distance/` | 64 B (visible), 4 KiB (offscreen), 64 KiB, 1 MiB, 8 MiB, or 32 MiB before the match in one 64 MiB resident file |
| `extent/` | Match near the end of a 64 MiB file, sole match at the cursor after a full wrap, or miss after a full pass. The origin is resident. |
| `readiness/` | Resident or unloaded 8 MiB destination. Both use a 1 MiB search distance and an 8 KiB origin file. |
| `files/` | One or 512 intervening unloaded files. Both use an 8 MiB search distance, equal total bytes, and 8 KiB origin and destination files. |
| `shape/` | An 8 MiB destination with one long line or a 64 MiB destination with ordinary lines. Compare with `readiness/unloaded` at the same 1 MiB distance. |

`search_distance_bytes` counts bytes before the match in forward order,
starting just after the cursor. A match at the next byte has distance zero.
A sole match at the cursor wraps and has distance `traversal_bytes - 1`.
Distances include newline bytes and exclude virtual file separators. The
counts describe fixture positions. Chunk reads, display preparation, and
destination loading can process additional bytes.

`traversal_bytes` sums all fixture file sizes. The report also records file
boundaries crossed before the match, destination size, matching line length,
and byte offset within that line. Misses report `null` for match distance and
boundary count. The `files/` pair crosses two or 513 boundaries because each
scenario has separate origin and destination files.

### Search validation and report

The benchmark checks the exact destination, matching bytes, expected message,
and generated frame. A miss must leave the cursor in place. Skipped files,
partial coverage, search failures, wrong destinations, and timeouts fail the
run. The benchmark also checks each sample's target residency and visibility,
discovered file count, iteration, and origin. It allows up to 30 seconds each
for the initial viewport to settle and for the search to finish.

The report defaults to `measurement/results/search-<UTC>.jsonl`. Its JSONL
records include `run` metadata, `scenario` configurations and fixture hashes,
`worker` build and workload settings, `sample` timings and validation, and
`complete` counts and `summary` timing for each scenario. A `run_end` record
reports the final status. Match fixture versions and viewport sizes when
comparing runs.
