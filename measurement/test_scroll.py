"""Exercise headless scrolling against disposable repositories and real files."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import scroll


BINARY = Path(sys.argv.pop(1)).resolve()
MIB = 1024 * 1024


class ScrollTests(unittest.TestCase):
    def invoke(self, repository, output, *arguments):
        return subprocess.run(
            [sys.executable, str(Path(scroll.__file__)), "--binary", str(BINARY),
             str(repository), "--rows", "6", "--cols", "40", "--output",
             str(output), *arguments],
            capture_output=True, text=True, timeout=30,
        )

    def completed(self, repository, output, *arguments):
        process = self.invoke(repository, output, *arguments)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        records = [json.loads(line) for line in output.read_text().splitlines()]
        self.assertEqual(records[-1]["type"], "run_end")
        self.assertEqual(records[-1]["status"], "complete")
        return records

    @staticmethod
    def repository_summary(records):
        return next(record for record in records
                    if record["type"] == "repository_summary")

    @staticmethod
    def scroll_summary(records):
        return next(record for record in records
                    if record["type"] == "summary"
                    and record["metric"] == "scroll_to_frame")

    def test_full_traversal_preserves_files_and_reports_production_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repo"
            (repository / "nested").mkdir(parents=True)
            (repository / ".git").mkdir()
            contents = {
                "a.txt": b"one\r\ntwo\r\n",
                ".hidden": b"",
                "nested/b.txt": b"\n".join([b"line"] * 20),
                ".git/ignored": b"not part of the editor workspace",
            }
            for name, data in contents.items():
                (repository / name).write_bytes(data)
            (repository / "link").symlink_to("a.txt")
            records = self.completed(repository, root / "full.jsonl")
            files = {record["file_name"]: record for record in records
                     if record["type"] == "file"}
            self.assertEqual(set(files), {"a.txt", ".hidden", "nested/b.txt"})
            self.assertTrue(all(file["loaded"] for file in files.values()))
            self.assertTrue(all(file["stats_status"] == "ok"
                                for file in files.values()))
            self.assertEqual(files["a.txt"]["byte_count"], 10)
            self.assertEqual(files["a.txt"]["line_count"], 3)
            self.assertEqual(files["a.txt"]["measured_line_count"], 3)
            self.assertEqual(files["a.txt"]["content_byte_count"], 6)
            self.assertEqual(files["a.txt"]["max_line_bytes"], 3)
            self.assertEqual(files["a.txt"]["line_size_counts"]["0"], 1)
            self.assertEqual(files[".hidden"]["line_count"], 1)
            summary = self.repository_summary(records)
            self.assertEqual(summary["file_count"], 3)
            self.assertEqual(summary["loaded_files"], 3)
            self.assertEqual(summary["failed_files"], 0)
            self.assertEqual(summary["unvisited_files"], 0)
            self.assertEqual(summary["total_lines"], 24)
            self.assertEqual(summary["total_bytes"], 109)
            for name, data in contents.items():
                self.assertEqual((repository / name).read_bytes(), data)
            self.assertTrue((repository / "link").is_symlink())

    def test_fixed_steps_count_events_and_distinguish_unvisited_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repo"
            repository.mkdir()
            (repository / "a.txt").write_bytes(b"line\n" * 100)
            (repository / "b.txt").write_bytes(b"later")
            records = self.completed(repository, root / "fixed.jsonl",
                                     "--steps", "3")
            samples = [record for record in records
                       if record["type"] == "sample"
                       and record["metric"] == "scroll_to_frame"]
            self.assertEqual(len(samples), 3)
            summary = self.scroll_summary(records)
            self.assertEqual(summary["sample_count"], 3)
            self.assertEqual(summary["total_ns"],
                             sum(sample["elapsed_ns"] for sample in samples))
            self.assertGreaterEqual(summary["max_ns"], summary["median_ns"])
            self.assertGreaterEqual(summary["max_ns"], summary["p95_ns"])
            inventory = self.repository_summary(records)
            self.assertEqual(inventory["file_count"], 2)
            self.assertEqual(inventory["loaded_files"], 1)
            self.assertEqual(inventory["unvisited_files"], 1)
            self.assertEqual(inventory["stats_files"], 2)

    def test_stats_handle_long_lines_and_crlf_across_read_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "long.txt"
            # The CR lands at the end of common power-of-two read chunks.
            path.write_bytes(b"x" * (MIB - 1) + b"\r\n" + b"tiny\r")
            stats = scroll.file_stats(path, 64 * MIB)
            self.assertEqual(stats["stats_status"], "ok")
            self.assertEqual(stats["byte_count"], MIB + 6)
            self.assertEqual(stats["line_count"], 2)
            self.assertEqual(stats["max_line_bytes"], MIB - 1)
            self.assertEqual(stats["content_byte_count"], MIB + 4)
            self.assertEqual(stats["mean_line_bytes"], (MIB + 4) / 2)
            self.assertEqual(stats["line_size_counts"], {
                "0": 0, "1-80": 1, "81-256": 0, "257-1024": 0,
                "1025-4096": 0, "4097-65536": 0, "65537+": 1,
            })

    def test_oversized_file_is_reported_without_becoming_a_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repo"
            repository.mkdir()
            with (repository / "a-oversized").open("wb") as file:
                file.truncate(64 * MIB + 1)
            (repository / "b-readable").write_bytes(b"readable")
            records = self.completed(repository, root / "oversized.jsonl",
                                     "--steps", "2")
            oversized = next(record for record in records
                             if record["type"] == "file"
                             and record["file_name"] == "a-oversized")
            self.assertEqual(oversized["error_name"], "FileTooBig")
            self.assertEqual(oversized["stats_status"], "oversized")
            self.assertFalse(oversized["loaded"])
            self.assertIsNone(oversized["line_count"])
            self.assertEqual(self.repository_summary(records)["failed_files"], 1)

    def test_empty_repository_completes_with_zero_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "empty"
            repository.mkdir()
            records = self.completed(repository, root / "empty.jsonl")
            summary = self.repository_summary(records)
            for field in ("file_count", "loaded_files", "failed_files",
                          "total_bytes", "total_lines", "stats_files",
                          "unvisited_files"):
                self.assertEqual(summary[field], 0, field)
            self.assertFalse(any(record["type"] == "file" for record in records))

    def test_output_refuses_overwrite_and_a_path_inside_the_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repo"
            repository.mkdir()
            (repository / "source").write_bytes(b"source")
            output = root / "existing.jsonl"
            output.write_text("preserve me\n")
            process = self.invoke(repository, output, "--steps", "1")
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(output.read_text(), "preserve me\n")
            internal = repository / "results.jsonl"
            process = self.invoke(repository, internal, "--steps", "1")
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(internal.exists())
            self.assertEqual(list(repository.iterdir()), [repository / "source"])


if __name__ == "__main__":
    unittest.main()
