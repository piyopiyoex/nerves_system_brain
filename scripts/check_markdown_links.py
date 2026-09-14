#!/usr/bin/env python3
"""Check relative links in tracked Markdown files without external packages."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


INLINE_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
REFERENCE_LINK_RE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(.+?)\s*$")
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")


def tracked_markdown_files(repo_root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.md"],
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [repo_root / path.decode() for path in result.stdout.split(b"\0") if path]


def link_destination(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("<"):
        end = raw.find(">")
        return raw[1:end] if end != -1 else raw
    return raw.split(maxsplit=1)[0] if raw else ""


def is_relative_file_link(destination: str) -> bool:
    if not destination or destination.startswith(("#", "/")):
        return False

    parsed = urlsplit(destination)
    return not parsed.scheme and not parsed.netloc and bool(parsed.path)


def check_file(repo_root: Path, markdown_file: Path) -> list[str]:
    errors: list[str] = []
    in_fence = False
    fence_char = ""
    fence_len = 0

    for line_number, line in enumerate(markdown_file.read_text(encoding="utf-8").splitlines(), 1):
        fence_match = FENCE_RE.match(line)
        if fence_match:
            marker = fence_match.group(1)
            if not in_fence:
                in_fence = True
                fence_char = marker[0]
                fence_len = len(marker)
            elif marker[0] == fence_char and len(marker) >= fence_len:
                in_fence = False
            continue

        if in_fence:
            continue

        destinations = [match.group(1) for match in INLINE_LINK_RE.finditer(line)]
        reference_match = REFERENCE_LINK_RE.match(line)
        if reference_match:
            destinations.append(reference_match.group(1))

        for raw_destination in destinations:
            destination = link_destination(raw_destination)
            if not is_relative_file_link(destination):
                continue

            path = unquote(urlsplit(destination).path)
            target = (markdown_file.parent / path).resolve()
            try:
                target.relative_to(repo_root)
            except ValueError:
                errors.append(
                    f"{markdown_file.relative_to(repo_root)}:{line_number}: "
                    f"relative link escapes repository: {destination}"
                )
                continue

            if not target.exists():
                errors.append(
                    f"{markdown_file.relative_to(repo_root)}:{line_number}: "
                    f"relative link target not found: {destination}"
                )

    return errors


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    errors: list[str] = []

    for markdown_file in tracked_markdown_files(repo_root):
        if markdown_file.is_file():
            errors.extend(check_file(repo_root, markdown_file))

    if errors:
        print("Broken Markdown relative links:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
