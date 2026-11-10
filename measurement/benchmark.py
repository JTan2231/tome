#!/usr/bin/env python3
"""Generate disposable inputs and summarize the production readiness boundary."""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import tempfile

from fixtures import GENERATOR_VERSION, Recipe, generate


ROOT = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024
SUITE_VERSION = 1


@dataclass(frozen=True)
class Scenario:
    name: str
    recipe: Recipe
    patterns: tuple = ("fresh", "repeat")
    file_count: int = 1
    missing: bool = False
    expected_error: str | None = None
    pressure_cache: str | None = None


def scenarios():
    cases = [
        Scenario(f"size/{label}", Recipe(size))
        for label, size in (
            ("64KiB", 64 * 1024), ("1MiB", MIB), ("8MiB", 8 * MIB),
            ("32MiB", 32 * MIB), ("64MiB", 64 * MIB),
        )
    ]
    cases += [
        Scenario("shape/one-line", Recipe(8 * MIB, None, final_newline=False)),
        Scenario("shape/4KiB-lines", Recipe(8 * MIB, 4096)),
        Scenario("shape/one-byte-lines", Recipe(8 * MIB, 1)),
        Scenario("shape/empty-lines", Recipe(8 * MIB, 0)),
    ]
    cases += [
        Scenario(f"outlier/{position}", Recipe(8 * MIB, outlier_position=position))
        for position in ("beginning", "middle", "end")
    ]
    cases += [
        Scenario("variant/crlf", Recipe(8 * MIB, newline="crlf")),
        Scenario("variant/no-final-newline", Recipe(8 * MIB, final_newline=False)),
        Scenario("variant/utf8", Recipe(8 * MIB, content="utf8")),
        Scenario("boundary/empty", Recipe(0)),
        Scenario("boundary/missing", Recipe(0), missing=True),
        Scenario("boundary/64MiB-minus-one", Recipe(64 * MIB - 1)),
        Scenario("boundary/64MiB-plus-one", Recipe(64 * MIB + 1),
                 expected_error="FileTooBig"),
    ]
    cases += [
        Scenario(f"cache/files-{count}", Recipe(4096), ("pressure",), count,
                 pressure_cache="miss" if count > 8 else "hit")
        for count in (7, 8, 9)
    ]
    cases += [
        Scenario(f"cache/bytes-{label}", Recipe(4 * MIB + delta), ("pressure",), 2,
                 pressure_cache="miss" if delta > 0 else "hit")
        for label, delta in (("below", -1), ("at", 0), ("above", 1))
    ]
    return cases


def schedule(case, pattern, repetitions):
    """Expected requests, including setup; never infer cache state from timing."""
    target = "file-000.txt"
    if pattern == "repeat":
        yield 0, "prime", target, "miss"
    for iteration in range(repetitions):
        if pattern == "pressure":
            yield iteration, "prime", target, "miss"
            for index in range(1, case.file_count):
                yield iteration, "pressure", f"file-{index:03}.txt", "miss"
        cache = {
            "fresh": "miss",
            "repeat": "cached_error" if case.expected_error else "hit",
            "pressure": case.pressure_cache,
        }[pattern]
        yield iteration, "sample", target, cache


def validate(sample, expected, case, fixtures):
    iteration, role, filename, cache = expected
    checks = {
        "type": "sample", "metric": "file_request_to_ready",
        "iteration": iteration, "role": role, "file_name": filename,
        "cache": cache,
        "outcome": "failed" if case.expected_error else "ready",
        "error_name": case.expected_error,
        "byte_count": None if case.expected_error else case.recipe.byte_count,
        "is_new": None if case.expected_error else case.missing,
        "line_count": None if case.expected_error else fixtures[filename]["line_count"],
    }
    errors = [f"{key}: expected {value!r}, got {sample.get(key)!r}"
              for key, value in checks.items() if key not in sample or sample[key] != value]
    elapsed = sample.get("elapsed_ns")
    if type(elapsed) is not int or elapsed < 0:
        errors.append("elapsed_ns must be a nonnegative integer")
    return errors


def emit(output, record):
    output.write(json.dumps(record, separators=(",", ":")) + "\n")
    output.flush()


def run_pattern(binary, case, pattern, repetitions, directory, fixtures, output):
    process = subprocess.run(
        [str(binary), pattern, str(repetitions), str(directory),
         str(directory / "file-000.txt")],
        capture_output=True, text=True,
    )
    records = [json.loads(line) for line in process.stdout.splitlines()]
    if not records or records[0].get("type") != "worker":
        raise ValueError(f"worker did not report build metadata: {process.stderr.strip()}")
    metadata = records.pop(0)
    # These named scenarios intentionally cover the documented production limits.
    for key, expected in (("max_file_size", 64 * MIB), ("cache_file_limit", 8),
                          ("cache_byte_limit", 8 * MIB)):
        if metadata.get(key) != expected:
            raise ValueError(f"{key} changed; update the benchmark boundary scenarios")
    emit(output, {**metadata, "scenario": case.name, "pattern": pattern})
    requests = list(schedule(case, pattern, repetitions))
    samples = []
    failures = []
    for index, record in enumerate(records):
        errors = (validate(record, requests[index], case, fixtures)
                  if index < len(requests) else ["unexpected extra request"])
        emit(output, {**record, "scenario": case.name, "pattern": pattern,
                      "valid": not errors, "validation_errors": errors})
        failures.extend(errors)
        if record.get("role") == "sample":
            samples.append(record)
    if process.returncode:
        failures.append(f"worker exited {process.returncode}: {process.stderr.strip()}")
    if len(records) != len(requests):
        failures.append(f"expected {len(requests)} requests, received {len(records)}")
    if failures:
        raise ValueError(f"{case.name}/{pattern}: " + "; ".join(failures[:5]))
    if case.missing and (directory / "file-000.txt").exists():
        raise ValueError("opening a missing file unexpectedly created it")
    elapsed = [sample["elapsed_ns"] for sample in samples]
    summary = {
        "type": "summary", "scenario": case.name, "pattern": pattern,
        "cache": samples[0]["cache"], "outcome": samples[0]["outcome"],
        "error_name": case.expected_error, "sample_count": len(samples),
        "median_ns": statistics.median(elapsed),
        "min_ns": min(elapsed), "max_ns": max(elapsed),
    }
    emit(output, summary)
    result = case.expected_error or "ready"
    print(f"{case.name:30} {pattern:8} {summary['cache']:12} {result:10} "
          f"{len(samples):4} {summary['median_ns'] / 1e6:11.6f} "
          f"{summary['min_ns'] / 1e6:11.6f} {summary['max_ns'] / 1e6:11.6f}",
          flush=True)


def run_suite(binary, cases, repetitions, output):
    for case in cases:
        # One scenario at a time bounds disk usage; cleanup also runs on errors
        # and Python's normal SIGINT/SIGTERM exception paths.
        with tempfile.TemporaryDirectory(prefix="tome-benchmark-") as temporary:
            directory = Path(temporary).resolve()
            fixtures = {}
            for index in range(case.file_count):
                filename = f"file-{index:03}.txt"
                if case.missing:
                    fixtures[filename] = {"byte_count": 0, "line_count": 1,
                                          "exists": False}
                else:
                    fixtures[filename] = generate(directory / filename, case.recipe)
            emit(output, {"type": "scenario", "scenario": case.name,
                          "patterns": case.patterns, "fixtures": fixtures,
                          "expected_error": case.expected_error,
                          "active_file": None})
            for pattern in case.patterns:
                run_pattern(binary, case, pattern, repetitions, directory,
                            fixtures, output)


def command_output(command):
    try:
        return subprocess.check_output(command, cwd=ROOT, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def run_metadata(repetitions):
    return {
        "type": "run", "suite_version": SUITE_VERSION, "generator_version": GENERATOR_VERSION,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "revision": command_output(["git", "rev-parse", "HEAD"]),
        "working_tree_dirty": bool(command_output(["git", "status", "--porcelain"])),
        "platform": platform.platform(), "architecture": platform.machine(),
        "cpu": (command_output(["sysctl", "-n", "machdep.cpu.brand_string"])
                if sys.platform == "darwin" else platform.processor()),
        "logical_cpus": os.cpu_count(), "python": platform.python_version(),
        "repetitions": repetitions, "os_cache": "uncontrolled; fixtures just generated",
        "fixture_storage": "system temporary directory; deleted after each scenario",
        "warmups": "no discarded samples; repeat primes retained but not summarized",
    }


def positive_int(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True,
                        help="benchmark worker (supplied by zig build benchmark)")
    parser.add_argument("--repetitions", type=positive_int, default=30)
    parser.add_argument("--scenario", action="append", default=[], metavar="PREFIX",
                        help="select scenario name prefixes; can be repeated")
    parser.add_argument("--list", action="store_true", help="list selected scenarios")
    parser.add_argument("--output", type=Path,
                        help="JSONL results path; default measurement/results/<UTC>.jsonl")
    args = parser.parse_args()
    cases = [case for case in scenarios()
             if not args.scenario or any(case.name.startswith(p) for p in args.scenario)]
    if not cases:
        parser.error("no scenarios match the supplied prefixes")
    if args.list:
        for case in cases:
            print(f"{case.name:30} {', '.join(case.patterns)}")
        return 0
    result_path = args.output or ROOT / "measurement/results" / (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + ".jsonl")
    result_path = result_path.resolve()
    result_path.parent.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, interrupted)
    print(f"Results: {result_path}", flush=True)
    print("Scenario                       Pattern  Cache        Outcome       n "
          "  Median ms      Min ms      Max ms", flush=True)
    with result_path.open("x") as output:
        emit(output, run_metadata(args.repetitions))
        try:
            run_suite(args.binary.resolve(), cases, args.repetitions, output)
        except (Exception, KeyboardInterrupt) as error:
            emit(output, {"type": "run_end", "status": "failed", "error": str(error)})
            print(f"benchmark: {error}", file=sys.stderr)
            return 1
        emit(output, {"type": "run_end", "status": "complete"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
