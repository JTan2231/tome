#!/usr/bin/env python3
"""Measure headless Page Down events through a real repository."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import heapq
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import tempfile
import time

from benchmark import ROOT, command_output, emit, interrupted, positive_int


LINE_BINS = ((0, "0"), (80, "1-80"), (256, "81-256"), (1024, "257-1024"),
             (4096, "1025-4096"), (65536, "4097-65536"), (math.inf, "65537+"))


def file_stats(path, max_file_size):
    """Post-run snapshot; bounded memory even for a file with one huge line.

    Lengths count content bytes, excluding LF and its immediately preceding CR.
    Like Tome, an empty file and the empty line after a final LF count as lines.
    """
    result = {"stats_status": "failed", "byte_count": None, "line_count": None,
              "content_byte_count": None, "max_line_bytes": None,
              "mean_line_bytes": None, "line_size_counts": None}
    try:
        before = path.stat()
        result.update(byte_count=before.st_size, mtime_ns=before.st_mtime_ns)
        if before.st_size > max_file_size:
            return {**result, "stats_status": "oversized"}
        counts = dict.fromkeys((name for _, name in LINE_BINS), 0)
        lines = content_bytes = longest = total = pending = 0
        last_byte = None
        digest = hashlib.sha256()

        def finish(length):
            nonlocal lines, content_bytes, longest
            lines += 1
            content_bytes += length
            longest = max(longest, length)
            for upper, name in LINE_BINS:
                if length <= upper:
                    counts[name] += 1
                    break

        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                total += len(chunk)
                if total > max_file_size:
                    return {**result, "stats_status": "oversized",
                            "stats_error": "file grew past the size limit"}
                digest.update(chunk)
                parts = chunk.split(b"\n")
                for part in parts[:-1]:
                    pending += len(part)
                    if part:
                        last_byte = part[-1]
                    finish(pending - (last_byte == 13))
                    pending = 0
                    last_byte = None
                pending += len(parts[-1])
                if parts[-1]:
                    last_byte = parts[-1][-1]
        finish(pending)
        after = path.stat()
        changed = (before.st_size, before.st_mtime_ns, before.st_ino) != (
            after.st_size, after.st_mtime_ns, after.st_ino)
        result.update(stats_status="ok", byte_count=total, line_count=lines,
                      content_byte_count=content_bytes, max_line_bytes=longest,
                      mean_line_bytes=content_bytes / lines, line_size_counts=counts,
                      sha256=digest.hexdigest(), changed_during_inventory=changed)
    except OSError as error:
        result["stats_error"] = str(error)
    return result


def timing_summary(metric, values):
    ordered = sorted(values)
    return {"type": "summary", "metric": metric, "sample_count": len(values),
            "total_ns": sum(values), "min_ns": min(values) if values else None,
            "median_ns": statistics.median(values) if values else None,
            "p95_ns": ordered[math.ceil(len(ordered) * .95) - 1] if ordered else None,
            "max_ns": max(values) if values else None,
            "over_16_67_ms": sum(value > 1e9 / 60 for value in values)}


def run_worker(binary, root, steps, rows, cols, output):
    worker = complete = None
    files = []
    timings = {"startup_to_frame": [], "scroll_to_frame": []}
    slowest = []
    last_progress = time.monotonic()
    started = last_progress
    # A file avoids blocking on a full stderr pipe while consuming stdout.
    with tempfile.TemporaryFile(mode="w+t") as errors:
        process = subprocess.Popen([str(binary), str(root), str(steps), str(rows), str(cols)],
                                   stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            for line in process.stdout:
                record = json.loads(line)
                kind = record.get("type")
                if kind == "worker":
                    if worker is not None:
                        raise ValueError("duplicate worker metadata")
                    worker = record
                elif kind == "sample":
                    metric = record.get("metric")
                    elapsed = record.get("elapsed_ns")
                    if metric not in timings or type(elapsed) is not int or elapsed < 0:
                        raise ValueError("invalid worker timing sample")
                    timings[metric].append(elapsed)
                    if metric == "scroll_to_frame":
                        item = (elapsed, record["iteration"], record)
                        heapq.heappush(slowest, item)
                        if len(slowest) > 10:
                            heapq.heappop(slowest)
                        now = time.monotonic()
                        if now - last_progress >= 5:
                            print(f"  {len(timings[metric]):,} pages; "
                                  f"current file index {record['file_index']}", flush=True)
                            last_progress = now
                elif kind == "file":
                    files.append(record)
                    record = {**record, "type": "catalog_file"}
                elif kind == "complete":
                    complete = record
                else:
                    raise ValueError(f"unexpected worker record: {kind!r}")
                emit(output, record)
            returncode = process.wait()
            errors.seek(0)
            if returncode:
                raise ValueError(f"worker exited {returncode}: {errors.read().strip()}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
    if worker is None or complete is None:
        raise ValueError("worker did not complete the traversal")
    if len(timings["startup_to_frame"]) != 1:
        raise ValueError("worker did not report exactly one startup sample")
    if len(files) != worker["discovered_files"] or len(files) != complete["discovered_files"]:
        raise ValueError("worker file inventory is incomplete")
    if [record["file_index"] for record in files] != list(range(len(files))):
        raise ValueError("worker file inventory is not in discovery order")
    if complete["steps"] != len(timings["scroll_to_frame"]):
        raise ValueError("worker scroll samples are incomplete")
    if steps and complete["steps"] != steps:
        raise ValueError("worker did not perform the requested step count")
    emit(output, {"type": "worker_wall", "elapsed_ns": int((time.monotonic() - started) * 1e9),
                  "includes": "process startup, discovery, measured work, and JSON reporting"})
    summaries = [timing_summary(metric, values) for metric, values in timings.items()]
    for summary in summaries:
        emit(output, summary)
    for _, _, record in sorted(slowest, reverse=True):
        index = record["file_index"]
        emit(output, {**record, "type": "slow_frame",
                      "file_name": files[index]["file_name"] if index is not None else None})
    return worker, complete, files, summaries, sorted(slowest, reverse=True)


def inventory(root, catalog, max_file_size, output):
    files = []
    for entry in catalog:
        measured_lines = entry["line_count"]
        record = {**entry, "measured_line_count": measured_lines,
                  "loaded": measured_lines is not None,
                  **file_stats(root / entry["file_name"], max_file_size)}
        record["line_count_matches_measurement"] = (
            record["line_count"] == measured_lines
            if measured_lines is not None and record["stats_status"] == "ok" else None)
        emit(output, record)
        files.append(record)
    scanned = [record for record in files if record["stats_status"] == "ok"]
    bins = Counter(dict.fromkeys((name for _, name in LINE_BINS), 0))
    for record in scanned:
        bins.update(record["line_size_counts"])
    summary = {
        "type": "repository_summary", "file_count": len(files),
        "loaded_files": sum(record["loaded"] for record in files),
        "failed_files": sum(record["error_name"] is not None for record in files),
        "unvisited_files": sum(not record["loaded"] and record["error_name"] is None
                               for record in files),
        "stats_files": len(scanned), "stats_unavailable_files": len(files) - len(scanned),
        "total_bytes": sum(record["byte_count"] or 0 for record in files),
        "total_lines": sum(record["line_count"] for record in scanned),
        "max_line_bytes": max((record["max_line_bytes"] for record in scanned), default=0),
        "line_size_counts": dict(bins),
        "changed_during_inventory": sum(record.get("changed_during_inventory", False)
                                        for record in files),
        "line_count_mismatches": sum(record["line_count_matches_measurement"] is False
                                     for record in files),
    }
    emit(output, summary)
    return summary, files


def print_results(worker, complete, summaries, repo, files, slowest):
    print(f"\nDiscovery: {worker['discovery_ns'] / 1e6:.3f} ms; "
          f"{complete['steps']:,} Page Down events ({complete['stop_reason']}).")
    for summary in summaries:
        if summary["sample_count"]:
            print(f"{summary['metric']}: total {summary['total_ns'] / 1e9:.3f} s; "
                  f"median {summary['median_ns'] / 1e6:.3f} ms; "
                  f"p95 {summary['p95_ns'] / 1e6:.3f} ms; "
                  f"max {summary['max_ns'] / 1e6:.3f} ms "
                  f"({summary['over_16_67_ms']:,} over 16.67 ms)")
    print(f"Files: {repo['file_count']:,} discovered, {repo['loaded_files']:,} loaded, "
          f"{repo['failed_files']:,} failed, {repo['unvisited_files']:,} unvisited.")
    print(f"Post-run inventory: {repo['total_bytes']:,} bytes, {repo['total_lines']:,} lines; "
          f"longest line {repo['max_line_bytes']:,} bytes "
          f"({repo['stats_unavailable_files']:,} files without line stats).")
    print("Line sizes (content bytes): " + ", ".join(
        f"{name}: {count:,}" for name, count in repo["line_size_counts"].items()))
    if repo["changed_during_inventory"] or repo["line_count_mismatches"]:
        print(f"Inventory changes: {repo['changed_during_inventory']} changed while scanning; "
              f"{repo['line_count_mismatches']} line counts differ from the measured workload.")
    print("Largest files (bytes / lines / longest line bytes):")
    for record in sorted(files, key=lambda item: item["byte_count"] or 0, reverse=True)[:5]:
        print(f"  {record['byte_count']} / {record['line_count']} / "
              f"{record['max_line_bytes']}  {record['file_name']}")
    print("Slowest scroll events (destination file; event can cross multiple files):")
    for elapsed, iteration, record in slowest[:5]:
        index = record["file_index"]
        name = files[index]["file_name"] if index is not None else "(empty workspace)"
        print(f"  {elapsed / 1e6:.3f} ms  page {iteration + 1:,}  {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--binary", type=Path, required=True,
                        help="worker supplied by zig build benchmark-scroll")
    parser.add_argument("--steps", type=positive_int,
                        help="fixed Page Down count; default stops at first wrap or end")
    parser.add_argument("--rows", type=positive_int, default=40)
    parser.add_argument("--cols", type=positive_int, default=120)
    parser.add_argument("--output", type=Path, help="new JSONL path outside the target tree")
    args = parser.parse_args()
    root = args.repository.expanduser().resolve()
    if not root.is_dir():
        parser.error(f"not a directory: {root}")
    if args.rows < 3 or args.cols < 2:
        parser.error("viewport requires at least 3 rows and 2 columns")
    stamp = datetime.now(timezone.utc).strftime("scroll-%Y%m%dT%H%M%S.%fZ.jsonl")
    default_directory = ROOT / "measurement/results"
    if default_directory.is_relative_to(root):
        default_directory = Path(tempfile.gettempdir()) / "tome-measurements"
    result_path = (args.output or default_directory / stamp).expanduser().resolve()
    if result_path.is_relative_to(root):
        parser.error("results must be outside the target tree to avoid measuring the report")
    result_path.parent.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, interrupted)
    print(f"Results: {result_path}\nRepository: {root}\n"
          f"Workload: {args.steps or 'one traversal'} Page Down; "
          f"{args.rows} rows x {args.cols} columns", flush=True)
    try:
        with result_path.open("x") as output:
            emit(output, {
                "type": "run", "suite": "repository_scroll", "suite_version": 1,
                "started_utc": datetime.now(timezone.utc).isoformat(), "repository": str(root),
                "revision": command_output(["git", "rev-parse", "HEAD"]),
                "working_tree_dirty": bool(command_output(["git", "status", "--porcelain"])),
                "repository_revision": command_output(["git", "-C", str(root), "rev-parse", "HEAD"]),
                "platform": platform.platform(), "architecture": platform.machine(),
                "logical_cpus": os.cpu_count(), "python": platform.python_version(),
                "steps": args.steps, "rows": args.rows, "cols": args.cols,
                "os_cache": "uncontrolled; no pre-run content inventory or discarded warmup",
                "workload": "Page Down then frame generation, sequentially without pacing",
                "excluded": "terminal input, terminal writes/display, JSON reporting, post-run inventory",
                "inventory": "post-run snapshot of discovered regular files; LF+1 logical lines",
            })
            try:
                worker, complete, catalog, summaries, slowest = run_worker(
                    args.binary.resolve(), root, args.steps or 0, args.rows, args.cols, output)
                print("Collecting post-run file and line statistics...", flush=True)
                repo, files = inventory(root, catalog, worker["max_file_size"], output)
                print_results(worker, complete, summaries, repo, files, slowest)
                emit(output, {"type": "run_end", "status": "complete"})
            except (Exception, KeyboardInterrupt) as error:
                emit(output, {"type": "run_end", "status": "failed", "error": str(error)})
                print(f"benchmark-scroll: {error}", file=sys.stderr)
                return 1
    except OSError as error:
        print(f"benchmark-scroll: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
