"""Check search measurements against known results, without timing thresholds."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import search


BINARY = Path(sys.argv.pop(1)).resolve()
RUNNER = Path(__file__).with_name("search.py")
QUERY = b"NEEDLE"


def text(*offsets, size=8192):
    """Short lines keep a six-row initial viewport inside the origin file."""
    data = bytearray((b"x" * 79 + b"\n") * (size // 80 + 1))[:size]
    for offset in offsets:
        data[offset:offset + len(QUERY)] = QUERY
    return bytes(data)


class SearchTests(unittest.TestCase):
    def invoke_runner(self, *arguments):
        return subprocess.run(
            [sys.executable, str(RUNNER), "--binary", str(BINARY), *arguments],
            capture_output=True, text=True, timeout=60,
        )

    def invoke_worker(self, root, contents, **options):
        workspace = root / "workspace"
        workspace.mkdir(exist_ok=True)
        for name, data in contents.items():
            (workspace / name).write_bytes(data)
        config = {
            "repetitions": 2, "rows": 6, "cols": 40,
            "origin_file": 0, "origin_offset": 0,
            "target_file": 0, "target_offset": 80,
            "preload_target": False, "query": QUERY.decode(),
            "expected_message": "Match", **options,
        }
        config_path = root / "config.json"
        config_path.write_text(json.dumps(config))
        process = subprocess.run(
            [str(BINARY), str(workspace), str(config_path)],
            capture_output=True, text=True, timeout=30,
        )
        records = [json.loads(line) for line in process.stdout.splitlines()]
        for name, data in contents.items():
            self.assertEqual((workspace / name).read_bytes(), data)
        return process, records

    def completed_worker(self, root, contents, **options):
        process, records = self.invoke_worker(root, contents, **options)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(records[0]["type"], "worker")
        self.assertEqual(records[-1]["type"], "complete")
        samples = [record for record in records if record["type"] == "sample"]
        self.assertEqual(len(samples), options.get("repetitions", 2))
        self.assertEqual(records[-1]["samples"], len(samples))
        found = options.get("target_file", 0) is not None
        for iteration, sample in enumerate(samples):
            self.assertEqual(sample["iteration"], iteration)
            self.assertEqual(sample["metric"], "search_to_frame")
            self.assertIs(type(sample["elapsed_ns"]), int)
            self.assertGreaterEqual(sample["elapsed_ns"], 0)
            self.assertGreater(sample["rendered_bytes"], 0)
            self.assertEqual(sample["outcome"], "match" if found else "not_found")
            self.assertEqual(sample["message"], options.get("expected_message", "Match"))
            self.assertEqual(sample["file_index"],
                             options.get("target_file", 0) if found
                             else options.get("origin_file", 0))
            self.assertEqual(sample["cursor_byte"],
                             options.get("target_offset", 80) if found
                             else options.get("origin_offset", 0))
        return samples

    def test_visible_and_offscreen_matches_are_distinguished(self):
        for offset, visible in ((80, True), (800, False)):
            with self.subTest(offset=offset), tempfile.TemporaryDirectory() as temporary:
                samples = self.completed_worker(
                    Path(temporary), {"a.txt": text(offset)}, target_offset=offset,
                )
                self.assertTrue(all(sample["target_resident_before"] for sample in samples))
                self.assertEqual([sample["target_visible_before"] for sample in samples],
                                 [visible] * len(samples))

    def test_fresh_repetitions_preserve_unloaded_and_preloaded_targets(self):
        for preload in (False, True):
            with self.subTest(preload=preload), tempfile.TemporaryDirectory() as temporary:
                samples = self.completed_worker(
                    Path(temporary), {"a.txt": text(), "b.txt": text(80)},
                    target_file=1, preload_target=preload, repetitions=3,
                )
                self.assertEqual([sample["target_resident_before"] for sample in samples],
                                 [preload] * 3)
                self.assertFalse(any(sample["target_visible_before"] for sample in samples))

    def test_search_starts_after_cursor_and_finds_the_next_occurrence(self):
        with tempfile.TemporaryDirectory() as temporary:
            samples = self.completed_worker(
                Path(temporary), {"a.txt": text(80, 800)},
                origin_offset=80, target_offset=800,
            )
            self.assertTrue(all(sample["target_resident_before"] for sample in samples))

    def test_a_sole_occurrence_at_cursor_is_found_only_after_wrapping(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.completed_worker(
                Path(temporary), {"a.txt": text(80)},
                origin_offset=80, target_offset=80,
                expected_message="Search wrapped",
            )

    def test_wrap_can_cross_the_end_of_the_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.completed_worker(
                Path(temporary), {"a.txt": text(80), "b.txt": text()},
                origin_file=1, target_file=0, expected_message="Search wrapped",
            )

    def test_no_match_completes_a_full_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            samples = self.completed_worker(
                Path(temporary), {"a.txt": text(), "b.txt": text()},
                origin_offset=800, target_file=None, target_offset=None,
                expected_message="Pattern not found",
            )
            self.assertTrue(all(sample["target_resident_before"] is None
                                for sample in samples))

    def test_wrong_expected_destination_is_a_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            process, records = self.invoke_worker(
                Path(temporary), {"a.txt": text(80)}, target_offset=81,
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(any(record["type"] == "complete" for record in records))

    def test_incomplete_coverage_cannot_count_as_a_successful_search(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            with (workspace / "b-oversized.txt").open("wb") as oversized:
                oversized.truncate(64 * 1024 * 1024 + 1)
            process, records = self.invoke_worker(
                root, {"a.txt": text(), "c.txt": text(80)}, target_file=2,
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(any(record["type"] == "complete" for record in records))
            self.assertEqual((workspace / "b-oversized.txt").stat().st_size,
                             64 * 1024 * 1024 + 1)

    def test_runner_records_validated_samples_and_latency_distribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "results.jsonl"
            process = self.invoke_runner(
                "--scenario", "readiness/unloaded", "--repetitions", "2",
                "--output", str(output),
            )
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            records = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(records[0]["type"], "run")
            self.assertEqual(records[-1]["type"], "run_end")
            self.assertEqual(records[-1]["status"], "complete")
            samples = [record for record in records if record["type"] == "sample"]
            self.assertEqual(len(samples), 2)
            self.assertTrue(all(record["valid"] for record in samples))
            self.assertFalse(any(record["target_resident_before"] for record in samples))
            summaries = [record for record in records if record["type"] == "summary"]
            self.assertEqual(len(summaries), 1)
            summary = summaries[0]
            self.assertEqual(summary["sample_count"], 2)
            self.assertLessEqual(summary["min_ns"], summary["median_ns"])
            self.assertLessEqual(summary["median_ns"], summary["p95_ns"])
            self.assertLessEqual(summary["p95_ns"], summary["max_ns"])

    def test_runner_lists_scenarios_and_refuses_to_overwrite_results(self):
        process = self.invoke_runner("--list", "--scenario", "readiness/")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn("readiness/resident", process.stdout)
        self.assertIn("readiness/unloaded", process.stdout)
        self.assertNotIn("extent/no-match", process.stdout)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "existing.jsonl"
            output.write_text("preserve this result\n")
            process = self.invoke_runner(
                "--scenario", "readiness/unloaded", "--repetitions", "1",
                "--output", str(output),
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(output.read_text(), "preserve this result\n")

    def test_fixture_metadata_matches_actual_bytes_and_search_order(self):
        cases = [
            search.Scenario("test/forward", (search.FileSpec(8192),
                                             search.FileSpec(4096, 65)), target_file=1),
            search.Scenario("test/wrapped", (search.FileSpec(8192, 65),),
                            origin_offset=65),
            search.Scenario("test/no-match", (search.FileSpec(8192),), target_file=None),
        ]
        for case in cases:
            with self.subTest(case=case.name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                metadata = search.generate_case(root, case, 1)
                contents = []
                for path in sorted(root.iterdir()):
                    data = path.read_bytes()
                    contents.append(data)
                    fixture = metadata["fixtures"][path.name]
                    self.assertEqual(fixture["byte_count"], len(data))
                    self.assertEqual(fixture["line_count"], data.count(b"\n") + 1)
                    self.assertEqual(fixture["sha256"], hashlib.sha256(data).hexdigest())
                whole = b"".join(contents)
                self.assertEqual(metadata["traversal_bytes"], len(whole))
                self.assertEqual(metadata["file_count"], len(contents))
                config = metadata["config"]
                needle = config["query"].encode()
                if config["target_file"] is None:
                    self.assertNotIn(needle, whole)
                    self.assertIsNone(metadata["search_distance_bytes"])
                    self.assertIsNone(metadata["file_boundaries_before_match"])
                    continue
                self.assertEqual(whole.count(needle), 1)
                origin = sum(map(len, contents[:config["origin_file"]])) + config["origin_offset"]
                match = whole.index(needle)
                self.assertEqual(metadata["search_distance_bytes"],
                                 (match - origin - 1) % len(whole))
                target = contents[config["target_file"]]
                offset = target.index(needle)
                self.assertEqual(config["target_offset"], offset)
                line_start = target.rfind(b"\n", 0, offset) + 1
                line_end = target.find(b"\n", offset)
                if line_end == -1:
                    line_end = len(target)
                self.assertEqual(metadata["target_line_offset_bytes"], offset - line_start)
                self.assertEqual(metadata["target_line_bytes"], line_end - line_start)

    def test_file_count_comparison_holds_distance_and_destination_constant(self):
        selected = [case for case in search.scenarios() if case.name.startswith("files/")]
        self.assertEqual(len(selected), 2)
        metadata = []
        for case in selected:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                record = search.generate_case(root, case, 1)
                metadata.append(record)
                files = sorted(root.iterdir())
                self.assertEqual(record["file_count"], len(files))
                self.assertEqual(record["traversal_bytes"],
                                 sum(path.stat().st_size for path in files))
                self.assertEqual(record["file_boundaries_before_match"], len(files) - 1)
                measured_distance = (sum(path.stat().st_size for path in files[:-1])
                                     + record["config"]["target_offset"] - 1)
                self.assertEqual(record["search_distance_bytes"], measured_distance)
        first, second = metadata
        for key in ("traversal_bytes", "search_distance_bytes", "target_file_bytes",
                    "target_line_offset_bytes", "expected_target_resident"):
            self.assertEqual(first[key], second[key], key)
        self.assertLess(first["file_boundaries_before_match"],
                        second["file_boundaries_before_match"])


if __name__ == "__main__":
    unittest.main()
