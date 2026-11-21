"""Per-case filesystem sandbox for differential parity runs.

Each case is materialized twice, once under a ``ref/`` root and once under a
``zig/`` root.  Both roots contain identical files, directories and symlinks;
the only difference is the binary that runs inside them.  Snapshots use
relative paths and record type, contents, permission bits and symlink targets,
so the two trees are directly comparable even though the absolute roots differ.
"""

from __future__ import annotations

import os
import stat
from typing import Any

Tree = dict[str, dict[str, Any]]

FILE_MODE = 0o644
DIR_MODE = 0o755


def _safe_relative(path: str) -> str:
    """Validate a case path and return its normalized in-sandbox relative form.

    Absolute paths and ``..`` components are rejected so a malformed case can
    never write outside its sandbox root.
    """
    if not isinstance(path, str) or not path:
        raise ValueError("invalid sandbox path: %r" % (path,))
    if os.path.isabs(path):
        raise ValueError("absolute sandbox path rejected: " + path)
    norm = os.path.normpath(path)
    if norm == ".." or norm.startswith(".." + os.sep) or norm == ".":
        raise ValueError("sandbox path escapes root: " + path)
    return norm


def _check_no_symlink_parents(root: str, rel: str) -> None:
    """Reject paths that would write through a symlink out of the sandbox."""
    parts = rel.split(os.sep)
    current = root
    for part in parts[:-1]:
        current = os.path.join(current, part)
        if os.path.islink(current):
            raise ValueError("sandbox path traverses a symlink: " + rel)


def _touch_parents(root: str, rel: str) -> None:
    _check_no_symlink_parents(root, rel)
    parent = os.path.dirname(rel)
    if parent:
        os.makedirs(os.path.join(root, parent), exist_ok=True)
        os.chmod(os.path.join(root, parent), DIR_MODE)


def materialize(case: dict, root: str) -> None:
    """Populate ``root`` with the files, directories and symlinks of ``case``.

    Modes are set explicitly rather than inheriting the process umask, so
    snapshots are identical on the reference and Zig sides.
    """
    os.makedirs(root, exist_ok=True)

    for raw in case.get("dirs", []) or []:
        rel = _safe_relative(raw)
        _check_no_symlink_parents(root, rel)
        os.makedirs(os.path.join(root, rel), exist_ok=True)
        os.chmod(os.path.join(root, rel), DIR_MODE)

    for raw, content in (case.get("files", {}) or {}).items():
        rel = _safe_relative(raw)
        _touch_parents(root, rel)
        path = os.path.join(root, rel)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(content)
        os.chmod(path, FILE_MODE)

    for raw, target in (case.get("symlinks", {}) or {}).items():
        rel = _safe_relative(raw)
        _touch_parents(root, rel)
        path = os.path.join(root, rel)
        if os.path.lexists(path):
            os.remove(path)
        os.symlink(target, path)


def snapshot(root: str) -> Tree:
    """Return a relative-path -> node map describing the tree under ``root``."""
    tree: Tree = {}

    def walk(rel: str) -> None:
        directory = os.path.join(root, rel) if rel else root
        with os.scandir(directory) as entries:
            for entry in entries:
                path = rel + "/" + entry.name if rel else entry.name
                info = entry.stat(follow_symlinks=False)
                mode = stat.S_IMODE(info.st_mode)
                if stat.S_ISLNK(info.st_mode):
                    tree[path] = {
                        "type": "symlink",
                        "mode": mode,
                        "target": os.readlink(entry.path),
                    }
                elif stat.S_ISDIR(info.st_mode):
                    tree[path] = {"type": "dir", "mode": mode}
                    walk(path)
                elif stat.S_ISREG(info.st_mode):
                    with open(entry.path, "rb") as fh:
                        content = fh.read()
                    tree[path] = {"type": "file", "mode": mode, "content": content}
                else:
                    tree[path] = {"type": "other", "mode": mode}

    walk("")
    return tree
