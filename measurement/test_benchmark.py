"""Exercise the generator/worker boundary, validation, and disposable inputs."""

import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import benchmark
from fixtures import Recipe


BINARY = Path(sys.argv.pop(1)).resolve()


class BenchmarkTests(unittest.TestCase):
    def run_cases(self, cases, repetitions=2):
        output = io.StringIO()
        directories = set()
        generate = benchmark.generate

        def track(path, recipe):
            directories.add(path.parent)
            return generate(path, recipe)

        with mock.patch.object(benchmark, "generate", side_effect=track):
            with contextlib.redirect_stdout(io.StringIO()):
                benchmark.run_suite(BINARY, cases, repetitions, output)
        self.assertTrue(all(not path.exists() for path in directories))
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_fresh_repeat_empty_and_missing(self):
        records = self.run_cases([
            benchmark.Scenario("empty", Recipe(0)),
            benchmark.Scenario("missing", Recipe(0), missing=True),
            benchmark.Scenario("utf8", Recipe(1025, newline="crlf", content="utf8")),
        ])
        summaries = [r for r in records if r["type"] == "summary"]
        self.assertEqual(len(summaries), 6)
        self.assertEqual([r["cache"] for r in summaries], ["miss", "hit"] * 3)
        self.assertTrue(all(r["sample_count"] == 2 for r in summaries))
        samples = [r for r in records if r["type"] == "sample"]
        self.assertEqual(len(samples), 15)  # Two misses, one prime, two hits per case.
        self.assertTrue(all(r["valid"] for r in samples))
        self.assertTrue(all(r["is_new"] == (r["scenario"] == "missing") for r in samples))

    def test_cache_pressure_crosses_each_budget_separately(self):
        cases = [case for case in benchmark.scenarios() if case.name.startswith("cache/")]
        records = self.run_cases(cases, repetitions=1)
        summaries = [r for r in records if r["type"] == "summary"]
        self.assertEqual([r["cache"] for r in summaries], ["hit", "hit", "miss"] * 2)
        self.assertTrue(all(r["sample_count"] == 1 for r in summaries))

    def test_expected_rejection_and_cached_error_are_separate_results(self):
        records = self.run_cases([
            benchmark.Scenario("oversized", Recipe(64 * benchmark.MIB + 1),
                               expected_error="FileTooBig")
        ])
        samples = [r for r in records if r["type"] == "sample"]
        self.assertTrue(all(r["outcome"] == "failed" and r["valid"] for r in samples))
        self.assertTrue(all(r["byte_count"] is None for r in samples))
        summaries = [r for r in records if r["type"] == "summary"]
        self.assertEqual([r["cache"] for r in summaries], ["miss", "cached_error"])

    def test_unexpected_outcome_prevents_a_summary(self):
        output = io.StringIO()
        case = benchmark.Scenario("wrong-expectation", Recipe(20), ("fresh",),
                                  expected_error="FileTooBig")
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "wrong-expectation/fresh"):
                benchmark.run_suite(BINARY, [case], 1, output)
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(any(r["type"] == "summary" for r in records))
        self.assertFalse(next(r for r in records if r["type"] == "sample")["valid"])

    def test_worker_failure_exits_nonzero_and_removes_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = root / "results.jsonl"
            process = subprocess.run(
                [sys.executable, str(benchmark.ROOT / "measurement/benchmark.py"),
                 "--binary", str(root / "absent-worker"), "--scenario", "boundary/empty",
                 "--repetitions", "1", "--output", str(result)],
                env={**os.environ, "TMPDIR": str(root)}, capture_output=True, text=True,
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(list(root.iterdir()), [result])
            records = [json.loads(line) for line in result.read_text().splitlines()]
            self.assertEqual(records[-1]["status"], "failed")

    def test_incomplete_worker_keeps_available_samples_without_summarizing(self):
        run = subprocess.run

        def truncated(*args, **kwargs):
            process = run(*args, **kwargs)
            process.returncode = 1
            process.stdout = "\n".join(process.stdout.splitlines()[:-1])
            process.stderr = "simulated setup failure after one request"
            return process

        output = io.StringIO()
        case = benchmark.Scenario("incomplete", Recipe(20), ("fresh",))
        with mock.patch.object(benchmark.subprocess, "run", side_effect=truncated):
            with self.assertRaisesRegex(ValueError, "worker exited 1"):
                benchmark.run_suite(BINARY, [case], 2, output)
        records = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(sum(r["type"] == "sample" for r in records), 1)
        self.assertFalse(any(r["type"] == "summary" for r in records))

    def test_termination_removes_inputs_and_stops_worker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = root / "results.jsonl"
            worker = root / "waiting-worker"
            marker = root / "started"
            worker.write_text(
                f"#!{sys.executable}\n"
                "import os, pathlib, time\n"
                f"pathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\n"
                "time.sleep(30)\n"
            )
            worker.chmod(0o755)
            process = subprocess.Popen(
                [sys.executable, str(benchmark.ROOT / "measurement/benchmark.py"),
                 "--binary", str(worker), "--scenario", "boundary/empty",
                 "--repetitions", "1", "--output", str(result)],
                env={**os.environ, "TMPDIR": str(root)},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                deadline = time.monotonic() + 10
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), "worker never started")
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=5)
                self.assertNotEqual(process.returncode, 0)
                self.assertFalse(list(root.glob("tome-benchmark-*")))
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(marker.read_text()), 0)
                records = [json.loads(line) for line in result.read_text().splitlines()]
                self.assertEqual(records[-1]["status"], "failed")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
