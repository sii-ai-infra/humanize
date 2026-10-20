#!/usr/bin/env python3
"""Read the current parts of an existing kernel goal tracker, without rewriting it.

Only recognized historical table rows are left for question-directed lookup.
Unknown sections, prose, unverified completion rows and fenced content stay.
An unfamiliar or incomplete tracker fails closed to the caller's full reader.
"""

import hashlib
from pathlib import Path
import re
import sys


HISTORY = {
    "Plan Evolution Log": ("Round", "Change", "Reason", "Impact on AC"),
    "Completed and Verified": ("AC", "Task", "Completed Round", "Verified Round", "Evidence"),
}
REQUIRED = {
    "IMMUTABLE SECTION", "MUTABLE SECTION", "Ultimate Goal", "Acceptance Criteria",
    "Active Tasks", "Blocking Side Issues", *HISTORY,
}


def headings(lines):
    result = []
    opaque = fenced_lines(lines)
    for index, line in enumerate(lines):
        if index not in opaque:
            match = re.match(r"^(#{1,6})\s+(.+?)\s*$", line)
            if match:
                result.append((index, len(match.group(1)), match.group(2)))
    return result


def fenced_lines(lines):
    """Mark fenced bodies as opaque; never interpret their example tables."""
    result = set()
    fence = None
    for index, line in enumerate(lines):
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if fence is not None:
            result.add(index)
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= fence[1]:
                if not line[marker.end():].strip():
                    fence = None
        elif marker:
            result.add(index)
            fence = (marker.group(1)[0], len(marker.group(1)))
    if fence is not None:
        raise ValueError("unclosed Markdown fence")
    return result


def cells(line):
    # Escaped pipes or unfamiliar table structure must not be silently cut.
    if "\\|" in line or not line.strip().startswith("|") or not line.strip().endswith("|"):
        return None
    return tuple(cell.strip() for cell in line.strip()[1:-1].split("|"))


def current_tracker(text):
    lines = text.splitlines(keepends=True)
    outline = headings(lines)
    opaque = fenced_lines(lines)
    names = [name for _, _, name in outline]
    if any(names.count(name) != 1 for name in REQUIRED):
        raise ValueError("missing or ambiguous tracker sections")
    if re.search(r"\[(?:To be extracted|To be defined|To be populated)", text, re.I):
        raise ValueError("tracker has not been initialized")
    replacements = {}
    omissions = {}
    for start, level, name in outline:
        if name not in HISTORY:
            continue
        end = next((index for index, other_level, _ in outline
                    if index > start and other_level <= level), len(lines))
        # A nested or custom history layout requires the original reader.
        if any(start < index < end for index, _, _ in outline):
            raise ValueError("nested historical sections")
        expected = HISTORY[name]
        body = lines[start + 1:end]
        kept = []
        omitted = 0
        table_seen = False
        index = 0
        while index < len(body):
            line = body[index]
            row = None if start + 1 + index in opaque else cells(line)
            if row != expected:
                # Preserve prose, code and unrecognized tables verbatim.
                kept.append(line)
                index += 1
                continue
            if table_seen or index + 1 >= len(body):
                raise ValueError("ambiguous historical table")
            separator = cells(body[index + 1])
            if separator is None or len(separator) != len(expected) or not all(
                re.fullmatch(r":?-{3,}:?", cell) for cell in separator
            ):
                raise ValueError("invalid historical table separator")
            table_seen = True
            header = body[index:index + 2]
            index += 2
            retained_rows = []
            while index < len(body) and body[index].lstrip().startswith("|"):
                row = cells(body[index])
                if row is None or len(row) != len(expected):
                    raise ValueError("unrecognized historical row")
                if name == "Completed and Verified" and not re.fullmatch(
                    r"(?:Round\s+)?\d+(?:\s+review)?", row[3], re.I
                ):
                    retained_rows.append(body[index])
                else:
                    omitted += 1
                index += 1
            if retained_rows:
                kept.extend(header + retained_rows)
        if not table_seen:
            raise ValueError("historical table missing")
        omissions[name] = omitted
        note = (
            f"\n[Default view omits {omitted} historical table rows from this section. "
            "Read the original rows for completion evidence, changed requirements, "
            "failed conditions or a specific trajectory question. Omission is not a "
            "claim that the rows are resolved, irrelevant or currently valid.]\n"
        )
        replacements[start] = (end, lines[start] + note + "".join(kept))
    output = []
    index = 0
    while index < len(lines):
        if index in replacements:
            end, replacement = replacements[index]
            output.append(replacement)
            index = end
        else:
            output.append(lines[index])
            index += 1
    return "".join(output), omissions


def main():
    if len(sys.argv) != 2:
        print("Usage: kernel-review-context.py TRACKER", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    try:
        raw = path.read_bytes()
        view, _ = current_tracker(raw.decode("utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"Kernel tracker view unavailable; read full tracker: {exc}", file=sys.stderr)
        return 1
    print(f"### Current tracker view\n\nSource: @{path.resolve()}")
    print(f"Source SHA256: {hashlib.sha256(raw).hexdigest()}")
    print("This is a read-only view, not a completion verdict. Read the original "
          "if state is missing, changed, contradictory or needs historical evidence.\n")
    print(view, end="" if view.endswith("\n") else "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
