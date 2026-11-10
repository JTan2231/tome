"""Generator correctness checks; no performance thresholds or retained inputs."""

import hashlib
from pathlib import Path
import tempfile
import unittest

from fixtures import CHUNK_BYTES, Recipe, generate


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tome-fixture-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "input"

    def check_recipe(self, recipe):
        metadata = generate(self.path, recipe)
        data = self.path.read_bytes()
        newline = b"\n" if recipe.newline == "lf" else b"\r\n"
        self.assertEqual(recipe.byte_count, len(data))
        self.assertEqual(metadata["byte_count"], len(data))
        self.assertEqual(metadata["newline_count"], data.count(b"\n"))
        self.assertEqual(metadata["line_count"], data.count(b"\n") + 1)
        self.assertEqual(metadata["max_line_bytes"], max(map(len, data.split(newline))))
        self.assertEqual(metadata["final_newline"], data.endswith(newline))
        self.assertEqual(metadata["sha256"], hashlib.sha256(data).hexdigest())
        data.decode("utf-8")
        if recipe.newline == "crlf":
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
            self.assertNotIn(b"\r", data.replace(b"\r\n", b""))
        if recipe.line_bytes is None:
            self.assertNotIn(b"\n", data)
        elif data:
            self.assertEqual(recipe.final_newline, data.endswith(newline))
        return data, metadata

    def test_exact_sizes_newlines_and_utf8_remainders(self):
        for newline in ("lf", "crlf"):
            for final in (False, True):
                for content in ("ascii", "utf8"):
                    for width in (0, 1, 80, 4096, None):
                        for size in (0, 2, 3, 79, 80, 81, 82, 163, CHUNK_BYTES + 5):
                            with self.subTest(newline=newline, final=final, content=content, width=width, size=size):
                                self.check_recipe(Recipe(size, width, newline, final, content))

    def test_profiles_are_deterministic(self):
        recipe = Recipe(200_003, 80, "crlf", False, "utf8", "middle")
        first_data, first = self.check_recipe(recipe)
        second_data, second = self.check_recipe(recipe)
        self.assertEqual(first_data, second_data)
        self.assertEqual(first, second)

    def test_outlier_is_one_complete_line_in_requested_region(self):
        for position in ("beginning", "middle", "end"):
            for newline in ("lf", "crlf"):
                for final in (False, True):
                    recipe = Recipe(100_003, 80, newline, final, "utf8", position)
                    with self.subTest(position=position, newline=newline, final=final):
                        data, metadata = self.check_recipe(recipe)
                        lines = data.split(b"\n" if newline == "lf" else b"\r\n")
                        if final:
                            lines.pop()
                        longest = max(range(len(lines)), key=lambda index: len(lines[index]))
                        self.assertEqual(len(lines[longest]), recipe.byte_count // 2)
                        self.assertEqual(metadata["max_line_bytes"], recipe.byte_count // 2)
                        self.assertEqual(sum(len(line) > 100 for line in lines), 1)
                        if position == "beginning":
                            self.assertEqual(longest, 0)
                        elif position == "end":
                            self.assertEqual(longest, len(lines) - 1)
                        else:
                            self.assertGreater(longest, 0)
                            self.assertLess(longest, len(lines) - 1)

    def test_lines_larger_than_write_chunk(self):
        self.check_recipe(Recipe(CHUNK_BYTES * 5 + 7, CHUNK_BYTES + 11, "crlf", True, "utf8"))

    def test_invalid_recipes_do_not_create_a_file(self):
        for recipe in (
            Recipe(-1), Recipe(10, -1), Recipe(10, newline="invalid"),
            Recipe(10, content="invalid"), Recipe(1, newline="crlf"),
            Recipe(10, outlier_position="beginning"),
            Recipe(1024, None, outlier_position="middle"),
            Recipe(1024, outlier_position="invalid"),
        ):
            with self.subTest(recipe=recipe), self.assertRaises(ValueError):
                generate(self.path, recipe)
            self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
