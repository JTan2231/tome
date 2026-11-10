"""Deterministic benchmark inputs; callers own their temporary directory."""

from dataclasses import asdict, dataclass
import hashlib
from pathlib import Path


GENERATOR_VERSION = 1
CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True)
class Recipe:
    byte_count: int
    line_bytes: int | None = 80
    newline: str = "lf"
    final_newline: bool = True
    content: str = "ascii"
    outlier_position: str | None = None


def _content(length, kind):
    if kind == "ascii":
        return b"x" * length
    scalar = "界".encode("utf-8")
    return scalar * (length // len(scalar)) + b"x" * (length % len(scalar))


class _Writer:
    def __init__(self, file, newline, kind):
        self.file = file
        self.newline_bytes = newline
        self.kind = kind
        self.digest = hashlib.sha256()
        self.byte_count = 0
        self.newline_count = 0
        self.current_line_bytes = 0
        self.max_line_bytes = 0
        self.final_newline = False

    def raw(self, data):
        self.file.write(data)
        self.digest.update(data)
        self.byte_count += len(data)

    def content(self, length):
        # A multiple of three keeps each UTF-8 chunk independently valid.
        chunk_size = CHUNK_BYTES - CHUNK_BYTES % 3
        block = _content(min(length, chunk_size), self.kind)
        remaining = length
        while remaining >= chunk_size:
            self.raw(block)
            remaining -= chunk_size
        if remaining:
            self.raw(_content(remaining, self.kind))
        self.current_line_bytes += length
        self.max_line_bytes = max(self.max_line_bytes, self.current_line_bytes)
        if length:
            self.final_newline = False

    def newline(self):
        self.raw(self.newline_bytes)
        self.newline_count += 1
        self.current_line_bytes = 0
        self.final_newline = True

    def records(self, line_bytes, count):
        if not count:
            return
        if line_bytes + len(self.newline_bytes) > CHUNK_BYTES:
            for _ in range(count):
                self.content(line_bytes)
                self.newline()
            return
        pattern = _content(line_bytes, self.kind) + self.newline_bytes
        batch = max(1, CHUNK_BYTES // len(pattern))
        block = pattern * batch
        remaining = count
        while remaining >= batch:
            self.raw(block)
            remaining -= batch
        if remaining:
            self.raw(pattern * remaining)
        self.max_line_bytes = max(
            self.max_line_bytes, self.current_line_bytes + line_bytes
        )
        self.current_line_bytes = 0
        self.newline_count += count
        self.final_newline = True

    def regular(self, size, line_bytes, final_newline):
        if not size:
            return
        # Reserve a terminal newline, or one content byte to prevent one.
        suffix = len(self.newline_bytes) if final_newline else 1
        records, remainder = divmod(size - suffix, line_bytes + len(self.newline_bytes))
        self.records(line_bytes, records)
        self.content(remainder if final_newline else remainder + 1)
        if final_newline:
            self.newline()


def generate(path: Path, recipe: Recipe) -> dict:
    """Write exactly byte_count bytes and return reproducibility/shape metadata.

    Ordinary lines have line_bytes content bytes, excluding LF or CRLF. The
    final remainder line may differ so that size and final-newline requirements
    are exact. line_bytes=None produces a single line without any newline.
    line_count follows Tome's convention: one plus the number of LF bytes.
    """
    if recipe.byte_count < 0 or (recipe.line_bytes is not None and recipe.line_bytes < 0):
        raise ValueError("byte_count and line_bytes must be nonnegative")
    if recipe.newline not in ("lf", "crlf") or recipe.content not in ("ascii", "utf8"):
        raise ValueError("expected lf/crlf newline and ascii/utf8 content")
    if recipe.outlier_position not in (None, "beginning", "middle", "end"):
        raise ValueError("outlier_position must be beginning, middle, or end")
    newline = b"\n" if recipe.newline == "lf" else b"\r\n"
    if recipe.line_bytes is not None and recipe.final_newline and 0 < recipe.byte_count < len(newline):
        raise ValueError("file is too small for the requested final newline")
    if recipe.outlier_position and (recipe.byte_count < 1024 or recipe.line_bytes is None):
        raise ValueError("outliers need at least 1024 bytes and a regular line length")

    with Path(path).open("wb") as file:
        writer = _Writer(file, newline, recipe.content)
        if recipe.line_bytes is None:
            writer.content(recipe.byte_count)
        elif recipe.outlier_position:
            outlier_bytes = recipe.byte_count // 2
            outlier_newline = recipe.outlier_position != "end" or recipe.final_newline
            remaining = recipe.byte_count - outlier_bytes - (len(newline) if outlier_newline else 0)
            before = {
                "beginning": 0,
                "middle": remaining // 2,
                "end": remaining,
            }[recipe.outlier_position]
            writer.regular(before, recipe.line_bytes, True)
            writer.content(outlier_bytes)
            if outlier_newline:
                writer.newline()
            writer.regular(remaining - before, recipe.line_bytes, recipe.final_newline)
        else:
            writer.regular(recipe.byte_count, recipe.line_bytes, recipe.final_newline)

    return {
        "generator_version": GENERATOR_VERSION,
        "recipe": asdict(recipe),
        "byte_count": writer.byte_count,
        "newline_count": writer.newline_count,
        "line_count": writer.newline_count + 1,
        "max_line_bytes": writer.max_line_bytes,
        "final_newline": writer.final_newline,
        "sha256": writer.digest.hexdigest(),
    }
