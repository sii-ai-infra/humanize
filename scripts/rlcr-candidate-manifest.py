#!/usr/bin/env python3
"""Emit a deterministic, binary manifest for RLCR solution candidates."""

from __future__ import annotations

import hashlib
import os
import posixpath
import stat
import sys
from typing import BinaryIO


EMPTY_SHA256 = hashlib.sha256(b"").hexdigest().encode("ascii")


def normalize_path(path: bytes) -> bytes:
    normalized = posixpath.normpath(path)
    if (
        not path
        or path.startswith(b"/")
        or normalized in (b"", b".", b"..")
        or normalized.startswith(b"../")
        or (normalized != b"solution" and not normalized.startswith(b"solution/"))
    ):
        raise ValueError(f"invalid solution path: {path!r}")
    return normalized


def file_type(mode: int) -> bytes:
    if stat.S_ISREG(mode):
        return b"regular"
    if stat.S_ISLNK(mode):
        return b"symlink"
    if stat.S_ISDIR(mode):
        return b"directory"
    if stat.S_ISFIFO(mode):
        return b"fifo"
    if stat.S_ISSOCK(mode):
        return b"socket"
    if stat.S_ISCHR(mode):
        return b"character-device"
    if stat.S_ISBLK(mode):
        return b"block-device"
    return b"unknown"


def regular_file_sha256(path: bytes) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    with os.fdopen(descriptor, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest().encode("ascii")


def describe(root: bytes, path: bytes) -> tuple[bytes, bytes, bytes, bytes]:
    full_path = os.path.join(root, *path.split(b"/"))
    try:
        metadata = os.lstat(full_path)
    except FileNotFoundError:
        # Cached paths remain in `git ls-files` after deletion.  The explicit
        # missing record is what makes deletion part of the fingerprint.
        return path, b"missing", b"0000", EMPTY_SHA256

    kind = file_type(metadata.st_mode)
    permissions = f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii")
    if kind == b"regular":
        content_sha256 = regular_file_sha256(full_path)
    elif kind == b"symlink":
        target = os.readlink(full_path)
        if isinstance(target, str):
            target = os.fsencode(target)
        content_sha256 = hashlib.sha256(target).hexdigest().encode("ascii")
    else:
        # Non-content-bearing filesystem entries still have a fixed-width
        # digest field; kind and mode distinguish them from an empty file.
        content_sha256 = EMPTY_SHA256
    return path, kind, permissions, content_sha256


def write_field(output: BinaryIO, name: bytes, value: bytes) -> None:
    output.write(name)
    output.write(b"=")
    output.write(str(len(value)).encode("ascii"))
    output.write(b":")
    output.write(value)
    output.write(b"\0")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: rlcr-candidate-manifest.py PROJECT_ROOT", file=sys.stderr)
        return 2

    raw_input = sys.stdin.buffer.read()
    raw_paths = raw_input.split(b"\0")
    if raw_paths and raw_paths[-1] == b"":
        raw_paths.pop()

    try:
        normalized_paths = [normalize_path(path) for path in raw_paths]
        if len(normalized_paths) != len(set(normalized_paths)):
            raise ValueError("duplicate normalized solution path")
        entries = [describe(os.fsencode(sys.argv[1]), path) for path in sorted(normalized_paths)]
    except (OSError, ValueError) as error:
        print(f"rlcr candidate manifest error: {error}", file=sys.stderr)
        return 2

    output = sys.stdout.buffer
    output.write(b"rlcr-solution-candidate-manifest-v1\0")
    for path, kind, permissions, content_sha256 in entries:
        output.write(b"entry\0")
        write_field(output, b"path", path)
        write_field(output, b"type", kind)
        write_field(output, b"mode", permissions)
        write_field(output, b"sha256", content_sha256)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
