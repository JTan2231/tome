#!/usr/bin/env python3
"""Benchmark literal search submission through the first result frame."""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile

from benchmark import ROOT, emit, interrupted, positive_int, run_metadata
from scroll import file_stats


MIB = 1024 * 1024
QUERY = "TOME_SEARCH_NEEDLE"
ROWS, COLS = 40, 120
SUITE_VERSION = 1


@dataclass(frozen=True)
class FileSpec:
    byte_count: int
    needle_offset: int | None = None
    line_bytes: int | None = 63


@dataclass(frozen=True)
class Scenario:
    name: str
    files: tuple[FileSpec, ...]
    target_file: int | None = 0
    origin_offset: int = 0
    preload_target: bool = False
    target_visible: bool = False


def scenarios():
    # Keep corpus size fixed while moving the sole occurrence. All these
    # searches start in the loaded file; distance does not imply disk I/O.
    cases = [Scenario(f"distance/{label}", (FileSpec(64 * MIB, distance + 1),),
                      target_visible=distance == 64)
             for label, distance in (("window-64B", 64), ("4KiB", 4096),
                                     ("64KiB", 65536), ("1MiB", MIB),
                                     ("8MiB", 8 * MIB), ("32MiB", 32 * MIB))]
    cases += [
        Scenario("extent/near-end", (FileSpec(64 * MIB, 64 * MIB - len(QUERY) - 1),)),
        Scenario("extent/wrapped-at-cursor", (FileSpec(64 * MIB, 0),),
                 target_visible=True),
        Scenario("extent/no-match", (FileSpec(64 * MIB),), target_file=None),
    ]
    origin = FileSpec(8192)
    target_offset = MIB + 1 - origin.byte_count
    pair = (origin, FileSpec(8 * MIB, target_offset))
    cases += [Scenario("readiness/resident", pair, target_file=1, preload_target=True),
              Scenario("readiness/unloaded", pair, target_file=1)]
    # Equal distance, target size, and residency; only intervening file count
    # changes. The origin and target are kept separate in both cases.
    body_bytes = 8 * MIB - origin.byte_count
    for count, label in ((1, "one-body"), (512, "512-bodies")):
        quotient, remainder = divmod(body_bytes, count)
        bodies = tuple(FileSpec(quotient + (index < remainder)) for index in range(count))
        cases.append(Scenario(f"files/{label}",
                              (origin, *bodies, FileSpec(8192, 1)),
                              target_file=count + 1))
    # Compare both with readiness/unloaded: same query and search distance.
    cases += [Scenario("shape/long-line", (origin, FileSpec(8 * MIB, target_offset, None)),
                       target_file=1),
              Scenario("shape/large-target", (origin, FileSpec(64 * MIB, target_offset)),
                       target_file=1)]
    return cases


def generate_file(path, spec):
    needle = QUERY.encode("ascii")
    if not 0 < spec.byte_count <= 64 * MIB:
        raise ValueError("fixture files must fit the production 64 MiB limit")
    pattern = b"x" if spec.line_bytes is None else b"x" * spec.line_bytes + b"\n"
    block = pattern * max(1, MIB // len(pattern))
    with path.open("wb") as destination:
        remaining = spec.byte_count
        while remaining:
            part = block[:min(remaining, len(block))]
            destination.write(part)
            remaining -= len(part)
    if spec.needle_offset is not None:
        if not 0 <= spec.needle_offset <= spec.byte_count - len(needle):
            raise ValueError("needle must fit within its file")
        with path.open("r+b") as destination:
            destination.seek(spec.needle_offset)
            replaced = destination.read(len(needle))
            if b"\n" in replaced:
                raise ValueError("needle must not overwrite a line boundary")
            destination.seek(spec.needle_offset)
            destination.write(needle)
    stats = file_stats(path, 64 * MIB)
    if stats["stats_status"] != "ok" or stats["byte_count"] != spec.byte_count:
        raise ValueError("fixture generation failed")
    return {**stats, "needle_offset": spec.needle_offset,
            "ordinary_line_bytes": spec.line_bytes}


def generate_case(directory, case, repetitions):
    fixtures = {f"file-{index:04}.txt": generate_file(directory / f"file-{index:04}.txt", spec)
                for index, spec in enumerate(case.files)}
    target = None if case.target_file is None else case.files[case.target_file]
    offset = None if target is None else target.needle_offset
    if target is not None and offset is None:
        raise ValueError("hit scenario requires a planted occurrence")
    wrapped = target is not None and case.target_file == 0 and offset <= case.origin_offset
    if target is None:
        distance = boundaries = line_offset = line_bytes = None
    else:
        if case.target_file == 0 and not wrapped:
            distance = offset - case.origin_offset - 1
            boundaries = 0
        else:
            preceding = case.files[1:] if wrapped else case.files[1:case.target_file]
            distance = case.files[0].byte_count - case.origin_offset - 1
            distance += sum(spec.byte_count for spec in preceding) + offset
            boundaries = len(case.files) if wrapped else case.target_file
        line_offset = offset if target.line_bytes is None else offset % (target.line_bytes + 1)
        line_bytes = (target.byte_count if target.line_bytes is None else
                      min(target.line_bytes, target.byte_count - (offset - line_offset)))
    config = {
        "repetitions": repetitions, "rows": ROWS, "cols": COLS,
        "origin_file": 0, "origin_offset": case.origin_offset,
        "target_file": case.target_file, "target_offset": offset,
        "preload_target": case.preload_target, "query": QUERY,
        "expected_message": "Pattern not found" if target is None else (
            "Search wrapped" if wrapped else "Match"),
    }
    return {
        "type": "scenario", "scenario": case.name, "config": config,
        "fixtures": fixtures, "file_count": len(case.files),
        "search_distance_bytes": distance,
        "traversal_bytes": sum(spec.byte_count for spec in case.files),
        "file_boundaries_before_match": boundaries,
        "target_file_bytes": None if target is None else target.byte_count,
        "target_line_offset_bytes": line_offset, "target_line_bytes": line_bytes,
        "expected_target_resident": None if target is None else (
            case.target_file == 0 or case.preload_target),
        "expected_target_visible": None if target is None else case.target_visible,
    }


def validate(sample, metadata, iteration):
    config = metadata["config"]
    hit = config["target_file"] is not None
    expected = {
        "type": "sample", "metric": "search_to_frame", "iteration": iteration,
        "origin_file": config["origin_file"], "origin_offset": config["origin_offset"],
        "file_index": config["target_file"] if hit else config["origin_file"],
        "cursor_byte": config["target_offset"] if hit else config["origin_offset"],
        "outcome": "match" if hit else "not_found", "message": config["expected_message"],
        "target_resident_before": metadata["expected_target_resident"],
        "target_visible_before": metadata["expected_target_visible"],
        "discovered_files": metadata["file_count"],
    }
    errors = [f"{key}: expected {value!r}, got {sample.get(key)!r}"
              for key, value in expected.items() if key not in sample or sample[key] != value]
    for key in ("elapsed_ns", "rendered_bytes", "resident_files_before"):
        if type(sample.get(key)) is not int or sample[key] < (0 if key == "elapsed_ns" else 1):
            errors.append(f"invalid {key}")
    return errors


def run_worker(binary, directory, config_path, metadata, output):
    repetitions = metadata["config"]["repetitions"]
    # Workers bound each search to 30 seconds. This outer limit also bounds
    # setup/teardown; failed and partial runs never produce success summaries.
    process = subprocess.run([str(binary), str(directory), str(config_path)],
                             capture_output=True, text=True,
                             timeout=60 + 35 * repetitions)
    worker = complete = None
    samples = []
    failures = []
    for line in process.stdout.splitlines():
        record = json.loads(line)
        kind = record.get("type")
        if kind == "worker" and worker is None and not samples and complete is None:
            worker = record
            if record.get("max_file_size") != 64 * MIB:
                failures.append("production file-size limit changed; update the fixtures")
        elif kind == "sample" and worker is not None and complete is None:
            errors = validate(record, metadata, len(samples))
            record = {**record, "valid": not errors, "validation_errors": errors}
            failures.extend(errors)
            samples.append(record)
        elif kind == "complete" and worker is not None and complete is None:
            complete = record
        else:
            failures.append(f"unexpected worker record: {kind!r}")
        emit(output, {**record, "scenario": metadata["scenario"]})
    if process.returncode:
        failures.append(f"worker exited {process.returncode}: {process.stderr.strip()}")
    if worker is None or complete is None:
        failures.append("worker did not complete")
    if len(samples) != repetitions or (complete is not None and complete.get("samples") != repetitions):
        failures.append("incorrect sample count")
    if failures:
        raise ValueError(f"{metadata['scenario']}: " + "; ".join(failures[:5]))
    values = sorted(sample["elapsed_ns"] for sample in samples)
    summary = {
        "type": "summary", "scenario": metadata["scenario"], "metric": "search_to_frame",
        "sample_count": len(values), "median_ns": statistics.median(values),
        "p95_ns": values[math.ceil(.95 * len(values)) - 1],
        "min_ns": values[0], "max_ns": values[-1],
        "outcome": samples[0]["outcome"],
        "search_distance_bytes": metadata["search_distance_bytes"],
        "file_boundaries_before_match": metadata["file_boundaries_before_match"],
        "target_resident_before": metadata["expected_target_resident"],
    }
    emit(output, summary)
    print(f"{metadata['scenario']:28} {len(values):4} "
          f"{summary['median_ns'] / 1e6:11.3f} {summary['p95_ns'] / 1e6:11.3f} "
          f"{summary['min_ns'] / 1e6:11.3f} {summary['max_ns'] / 1e6:11.3f}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True,
                        help="worker supplied by zig build benchmark-search")
    parser.add_argument("--repetitions", type=positive_int, default=30)
    parser.add_argument("--scenario", action="append", default=[], metavar="PREFIX")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--output", type=Path, help="new JSONL path")
    args = parser.parse_args()
    cases = [case for case in scenarios()
             if not args.scenario or any(case.name.startswith(prefix) for prefix in args.scenario)]
    if not cases:
        parser.error("no scenarios match the supplied prefixes")
    if args.list:
        for case in cases:
            print(case.name)
        return 0
    stamp = datetime.now(timezone.utc).strftime("search-%Y%m%dT%H%M%S.%fZ.jsonl")
    result_path = (args.output or ROOT / "measurement/results" / stamp).expanduser().resolve()
    signal.signal(signal.SIGTERM, interrupted)
    print(f"Results: {result_path}", flush=True)
    print("Scenario                        n   Median ms      p95 ms      Min ms      Max ms", flush=True)
    try:
        result_path.parent.mkdir(parents=True, exist_ok=True)
        with result_path.open("x") as output:
            emit(output, {**run_metadata(args.repetitions),
                          "suite": "search", "suite_version": SUITE_VERSION,
                          "generator_version": 1, "rows": ROWS, "cols": COLS,
                          "warmups": "none discarded; new workspace and editor for each sample",
                          "boundary": "Enter submission through search completion and first result frame",
                          "scheduling": "headless tick servicing with Thread.yield; no terminal poll delay",
                          "distance": "bytes before match start in forward order, excluding origin byte; positional, not bytes actually read",
                          "excluded": "fixture generation, discovery, initial file loading/frame, preload, query entry, JSON reporting, terminal I/O/display"})
            try:
                for case in cases:
                    with tempfile.TemporaryDirectory(prefix="tome-search-") as temporary:
                        directory = Path(temporary) / "workspace"
                        directory.mkdir()
                        metadata = generate_case(directory, case, args.repetitions)
                        emit(output, metadata)
                        config_path = Path(temporary) / "config.json"
                        config_path.write_text(json.dumps(metadata["config"]))
                        run_worker(args.binary.resolve(), directory, config_path, metadata, output)
                emit(output, {"type": "run_end", "status": "complete"})
            except (Exception, KeyboardInterrupt) as error:
                emit(output, {"type": "run_end", "status": "failed", "error": str(error)})
                print(f"benchmark-search: {error}", file=sys.stderr)
                return 1
    except OSError as error:
        print(f"benchmark-search: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
