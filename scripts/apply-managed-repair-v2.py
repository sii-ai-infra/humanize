#!/usr/bin/python3.12
"""Fixed Native v2 repair effects; prepare is read-only, apply needs Node's
protected operation. This helper cannot prove a user answer or mint a permit.
Run with the fixed interpreter -I -S -B and supervisor identity.
"""
import argparse
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 1024 * 1024
DOCUMENT = 2 * 1024 * 1024
STATES = ("state.md", "finalize-state.md", "methodology-analysis-state.md", "complete-state.md",
          "cancel-state.md", "maxiter-state.md", "stop-state.md", "unexpected-state.md")
ACTIVE = STATES[:3]
FLAGS = (".review-phase-started", ".methodology-exit-reason")
DECIMAL = re.compile(r"(?:0|[1-9][0-9]{0,17})\Z")
ULID = re.compile(r"[0-7][0-9A-HJKMNP-TV-Z]{25}\Z")


def exact(value, names):
    if type(value) is not dict or set(value) != set(names):
        raise ValueError("closed native schema differs")


def digest(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("duplicate native metadata key")
        result[key] = value
    return result


def decode_metadata(data):
    if len(data) > LIMIT:
        raise ValueError("native operation exceeds 1MiB")
    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid constant")))


def checked_metadata(info, directory=False, ancestor=False):
    if info.st_uid not in {0, os.geteuid()} or (directory and not stat.S_ISDIR(info.st_mode)):
        raise ValueError("native file/directory is not supervisor owned")
    writable = info.st_mode & 0o022
    if writable and not (ancestor and stat.S_ISDIR(info.st_mode) and info.st_mode & stat.S_ISVTX):
        raise ValueError("native authority is group/other writable")
    if not ancestor and info.st_mode & 0o7000:
        raise ValueError("native leaf has special mode bits")
    if not directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid()):
        raise ValueError("native file is not a single supervisor-owned regular file")


def directory(path):
    if not path.is_absolute() or path != path.resolve(strict=True):
        raise ValueError("native authority path is not canonical")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        checked_metadata(os.fstat(fd), directory=True, ancestor=True)
        for index, name in enumerate(path.parts[1:]):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd); fd = child
            checked_metadata(os.fstat(fd), directory=True, ancestor=index+2 < len(path.parts))
        return fd
    except BaseException:
        os.close(fd); raise


def read(fd, name, limit=DOCUMENT):
    try:
        handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(handle); checked_metadata(info)
        if info.st_size > limit:
            raise ValueError("native file exceeds its bound")
        with os.fdopen(os.dup(handle), "rb") as stream:
            data = stream.read(limit+1)
        if len(data) > limit or len(data) != info.st_size:
            raise ValueError("native file changed while reading")
        return data, stat.S_IMODE(info.st_mode)
    finally:
        os.close(handle)


def capture(fd, round_number):
    names = set(STATES + FLAGS) | {f"round-{round_number}-benchmark.md", f"round-{round_number}-benchmark.log",
        f"round-{round_number}-completion-blocked.md", f"round-{round_number}-prompt.md", f"round-{round_number+1}-prompt.md"}
    entries = os.listdir(fd)
    if len(entries) > 100_000:
        raise ValueError("native directory entry limit")
    for name in entries:
        if name.startswith("round-") and name.endswith("-prompt.md"):
            matched = re.fullmatch(r"round-(0|[1-9][0-9]*)-prompt\.md", name)
            if matched is None or len(matched[1]) > 20 or int(matched[1]) > 2**64-1:
                raise ValueError("noncanonical native prompt path")
            names.add(name)
    if len(names) > 4096:
        raise ValueError("native manifest entry limit")
    files = {}; modes = {}
    for name in sorted(names):
        value = read(fd, name, 17*1024*1024 if name.endswith("-benchmark.log") else DOCUMENT)
        files[name] = digest(value[0]) if value is not None else None
        modes[name] = value[1] if value is not None else None
    return {"schema": "node-native-pause-manifest-v2", "round": round_number, "files": files}, modes


def validate_manifest(value, modes, round_number):
    exact(value, ("schema", "round", "files"))
    if (value["schema"] != "node-native-pause-manifest-v2" or type(value["round"]) is not int
        or value["round"] != round_number or type(value["files"]) is not dict or len(value["files"]) > 4096
        or type(modes) is not dict or modes.keys() != value["files"].keys()):
        raise ValueError("native manifest schema/round/modes differ")
    required = set(STATES + FLAGS) | {f"round-{round_number}-benchmark.md", f"round-{round_number}-benchmark.log",
        f"round-{round_number}-completion-blocked.md", f"round-{round_number}-prompt.md", f"round-{round_number+1}-prompt.md"}
    if not required <= value["files"].keys():
        raise ValueError("native manifest omits required absence facts")
    for name, entry in value["files"].items():
        if name not in required:
            matched = re.fullmatch(r"round-(0|[1-9][0-9]*)-prompt\.md", name)
            if matched is None or len(matched[1]) > 20 or int(matched[1]) > 2**64-1:
                raise ValueError("unexpected native manifest path")
        if entry is None:
            if modes[name] is not None:
                raise ValueError("absent native file has a mode")
        else:
            exact(entry, ("bytes", "sha256"))
            if (type(entry["bytes"]) is not int or not 0 <= entry["bytes"] <= (17*1024*1024 if name.endswith("-benchmark.log") else DOCUMENT)
                or type(entry["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])):
                raise ValueError("native manifest digest differs")
            validate_mode(modes[name])


def validate_mode(mode):
    if type(mode) is not int or not 0 <= mode <= 0o777 or mode & 0o022:
        raise ValueError("native effect has an unprotected mode")


def receipt(data, phase):
    # Absolute, fixed bundle import; isolated Python never imports task cwd.
    path = ROOT / "scripts/validate-managed-receipt-v2.py"
    if path.is_symlink() or not path.is_file():
        raise ValueError("fixed native decoder unavailable")
    spec = importlib.util.spec_from_file_location("fixed_native_receipt_v2", path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    value = module.decode(data, phase)
    if value["decision"] != "repair":
        raise ValueError("only an authorized repair operation has native effects")
    return value


def prepare(fd, args, value):
    before, modes = capture(fd, args.expected_round)
    present = [name for name in STATES if before["files"][name] is not None]
    if len(present) != 1 or present[0] not in ACTIVE:
        raise ValueError("native active/target lifecycle conflict")
    active = present[0]
    # Fixed sticky system temp, never a task-supplied TMPDIR. The random child
    # is owned by this supervisor with mode0700.
    parent = os.open("/tmp", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        checked_metadata(os.fstat(parent), directory=True, ancestor=True)
    finally:
        os.close(parent)
    with tempfile.TemporaryDirectory(prefix="native-repair-v2-", dir="/tmp") as temporary:
        work = Path(temporary) / "loop"; work.mkdir(mode=0o700)
        # Only the native transition's possible files are copied. History,
        # source and large benchmark capture are never executed or modified.
        possible = set(STATES + FLAGS) | {f"round-{args.expected_round+1}-prompt.md", f"round-{args.expected_round}-completion-blocked.md"}
        for name in possible:
            current = read(fd, name)
            if (digest(current[0]) if current is not None else None) != before["files"][name] or (current[1] if current is not None else None) != modes[name]:
                raise ValueError("native copy differs from Before")
            if current is not None:
                (work/name).write_bytes(current[0]); (work/name).chmod(current[1])
        received = Path(temporary) / "receipt.json"; received.write_bytes(canonical(value)); received.chmod(0o600)
        script = ROOT / "scripts/prepare-managed-repair-v2.sh"
        if script.is_symlink() or not script.is_file():
            raise ValueError("fixed native prepare shell unavailable")
        completed = subprocess.run(["/bin/bash", "--noprofile", "--norc", str(script), str(work), active,
            str(args.expected_round), str(received)], cwd=temporary, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True)
        if completed.returncode != 0 or len(completed.stdout) > 64*1024:
            raise ValueError("fixed native prepare rejected state/budget")
        effects = []; after = json.loads(json.dumps(before)); after_modes = dict(modes)
        for name in sorted(possible):
            original = read(fd, name)
            if (work/name).exists():
                data = (work/name).read_bytes(); mode = stat.S_IMODE((work/name).stat().st_mode)
                changed = original is None or original != (data, mode)
                final = {"data": base64.b64encode(data).decode("ascii"), "mode": mode}
                after["files"][name] = digest(data); after_modes[name] = mode
            else:
                changed = original is not None; final = None
                after["files"][name] = None; after_modes[name] = None
            if changed:
                effects.append({"path": name, "after": final})
        # No caller lock or live mutation: detect a writer racing prepare.
        if capture(fd, args.expected_round) != (before, modes):
            raise ValueError("native Before changed during prepare")
        info = os.fstat(fd)
        plan = {"schema": "humanize-native-repair-plan-v2", "operation_id": args.operation,
            "phase": args.phase, "before_round": args.expected_round,
            "loop": {"path": str(args.loop_dir), "device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid},
            "receipt_sha256": hashlib.sha256(canonical(value)).hexdigest(),
            "before": before, "before_modes": modes, "expected_after": after, "after_modes": after_modes,
            "effects": effects, "native_stdout": base64.b64encode(completed.stdout).decode("ascii")}
        encoded = canonical(plan)
        if len(encoded) + 1 > LIMIT:
            raise ValueError("native effects exceed 1MiB")
        return encoded + b"\n"


def apply(fd, args, value):
    if args.plan is None:
        raise ValueError("protected Node plan required")
    if args.plan.is_relative_to(args.loop_dir):
        raise ValueError("Node repair plan must be outside the guarded loop")
    parent = directory(args.plan.parent)
    try:
        stored = read(parent, args.plan.name, LIMIT)
    finally:
        os.close(parent)
    if stored is None:
        raise ValueError("protected Node plan missing")
    expected_sha = args.plan_sha256
    if args.intent is not None:
        parent = directory(args.intent.parent)
        try:
            intent_bytes = read(parent, args.intent.name, 16*1024)
        finally:
            os.close(parent)
        if intent_bytes is None or args.intent.is_relative_to(args.loop_dir):
            raise ValueError("protected Node intent missing or inside loop")
        intent = decode_metadata(intent_bytes[0])
        exact(intent, ("schema", "state", "operation_id", "phase", "before_round", "receipt_sha256", "plan_sha256"))
        if (intent["schema"] != "humanize-native-repair-intent-v2" or intent["state"] != "native_apply_pending"
            or intent["operation_id"] != args.operation or intent["phase"] != args.phase
            or type(intent["before_round"]) is not int or intent["before_round"] != args.expected_round
            or intent["receipt_sha256"] != hashlib.sha256(canonical(value)).hexdigest()
            or intent_bytes[0] != canonical(intent)+b"\n"):
            raise ValueError("Node repair intent does not bind this operation")
        expected_sha = intent["plan_sha256"]
    if type(expected_sha) is not str or not re.fullmatch(r"[a-f0-9]{64}", expected_sha) or hashlib.sha256(stored[0]).hexdigest() != expected_sha:
        raise ValueError("native plan bytes differ from protected intent SHA")
    plan = decode_metadata(stored[0])
    if stored[0] != canonical(plan)+b"\n":
        raise ValueError("native plan does not have canonical UTF8 bytes")
    exact(plan, ("schema", "operation_id", "phase", "before_round", "loop", "receipt_sha256", "before", "before_modes", "expected_after", "after_modes", "effects", "native_stdout"))
    exact(plan["loop"], ("path", "device", "inode", "uid"))
    if any(type(plan["loop"][key]) is not int for key in ("device", "inode", "uid")):
        raise ValueError("native loop identity has invalid integer types")
    info = os.fstat(fd)
    if (plan["schema"] != "humanize-native-repair-plan-v2" or plan["operation_id"] != args.operation
        or plan["phase"] != args.phase or type(plan["before_round"]) is not int or plan["before_round"] != args.expected_round
        or plan["loop"] != {"path": str(args.loop_dir), "device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid}
        or plan["receipt_sha256"] != hashlib.sha256(canonical(value)).hexdigest()):
        raise ValueError("native plan operation/receipt/phase/loop/round differs")
    validate_manifest(plan["before"], plan["before_modes"], args.expected_round)
    validate_manifest(plan["expected_after"], plan["after_modes"], args.expected_round)
    if type(plan["effects"]) is not list or not 1 <= len(plan["effects"]) <= 8:
        raise ValueError("native effects cardinality differs")
    expected = json.loads(json.dumps(plan["before"])); expected_modes = dict(plan["before_modes"])
    allowed = set(ACTIVE + ("maxiter-state.md",) + FLAGS) | {f"round-{args.expected_round+1}-prompt.md", f"round-{args.expected_round}-completion-blocked.md"}
    paths = set(); decoded = []
    for effect in plan["effects"]:
        exact(effect, ("path", "after")); name = effect["path"]
        if name not in allowed or name in paths:
            raise ValueError("native effect has unexpected/duplicate path")
        paths.add(name); final = effect["after"]
        if final is not None:
            exact(final, ("data", "mode"))
            validate_mode(final["mode"])
            data = base64.b64decode(final["data"], validate=True)
            if len(data) > DOCUMENT:
                raise ValueError("native effect document exceeds bound")
            expected["files"][name] = digest(data); expected_modes[name] = final["mode"]
        else:
            data = None; expected["files"][name] = None; expected_modes[name] = None
        decoded.append((name, data, final["mode"] if final is not None else None))
    if expected != plan["expected_after"] or expected_modes != plan["after_modes"]:
        raise ValueError("native expected effects are internally inconsistent")
    present = [name for name in STATES if expected["files"][name] is not None]
    unchanged = lambda name: (expected["files"][name], expected_modes[name]) == (plan["before"]["files"][name], plan["before_modes"][name])
    if present == ["state.md"]:
        shape = (expected["files"][f"round-{args.expected_round+1}-prompt.md"] is not None
            and unchanged(f"round-{args.expected_round}-completion-blocked.md")
            and all(expected["files"][name] is None for name in FLAGS))
    elif present == ["maxiter-state.md"]:
        shape = (expected["files"][f"round-{args.expected_round}-completion-blocked.md"] is not None
            and unchanged(f"round-{args.expected_round+1}-prompt.md") and unchanged(".review-phase-started")
            and expected["files"][".methodology-exit-reason"] is None)
    else:
        shape = False
    if not shape:
        raise ValueError("native effects would violate active/terminal state shape")
    output = base64.b64decode(plan["native_stdout"], validate=True)
    if len(output) > 64*1024:
        raise ValueError("native stdout exceeds bound")
    current = capture(fd, args.expected_round)
    if current == (plan["expected_after"], plan["after_modes"]):
        return output  # Same operation, no new transition or file write.
    if current != (plan["before"], plan["before_modes"]):
        raise ValueError("partial/conflicting native operation requires reconciliation")
    # Text first, flags next, state last. Partial crashes remain reconcile;
    # no attempt to manufacture a completed transition from a round number.
    decoded.sort(key=lambda item: (2 if item[1] is not None else 3) if item[0] in STATES else 1 if item[0] in FLAGS else 0)
    for name, data, mode in decoded:
        verify_loop_inode(fd, args.loop_dir)
        if data is None:
            os.unlink(name, dir_fd=fd)
        else:
            temporary = ".native-repair-" + os.urandom(16).hex()
            handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
            try:
                with os.fdopen(handle, "wb", closefd=False) as stream:
                    stream.write(data); stream.flush(); os.fchmod(handle, mode); os.fsync(handle)
                os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
            finally:
                os.close(handle)
                try: os.unlink(temporary, dir_fd=fd)
                except FileNotFoundError: pass
        os.fsync(fd)
    verify_loop_inode(fd, args.loop_dir)
    if capture(fd, args.expected_round) != (plan["expected_after"], plan["after_modes"]):
        raise ValueError("native effects did not settle completely")
    return output


def verify_loop_inode(fd, path):
    named = os.stat(path, follow_symlinks=False); held = os.fstat(fd)
    if (named.st_dev, named.st_ino) != (held.st_dev, held.st_ino):
        raise ValueError("native loop directory replaced during operation")


def validate_bundle():
    for relative in ("scripts/apply-managed-repair-v2.py", "scripts/prepare-managed-repair-v2.sh",
                     "scripts/validate-managed-receipt-v2.py", "hooks/lib/loop-common.sh"):
        path = ROOT/relative; parent = directory(path.parent)
        try:
            if read(parent, path.name) is None:
                raise ValueError("fixed native bundle resource missing")
        finally:
            os.close(parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true"); parser.add_argument("--plan", type=Path)
    binding = parser.add_mutually_exclusive_group()
    binding.add_argument("--plan-sha256"); binding.add_argument("--intent", type=Path)
    parser.add_argument("--phase", choices=("round", "completion"), required=True)
    parser.add_argument("--operation", required=True); parser.add_argument("--loop-dir", type=Path, required=True)
    parser.add_argument("--expected-round", required=True)
    args = parser.parse_args()
    try:
        if not ULID.fullmatch(args.operation) or not DECIMAL.fullmatch(args.expected_round):
            raise ValueError("native operation/round is not canonical")
        args.expected_round = int(args.expected_round)
        validate_bundle()
        value = receipt(sys.stdin.buffer.read(64*1024+1), args.phase)
        fd = directory(args.loop_dir)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            verify_loop_inode(fd, args.loop_dir)
            output = prepare(fd, args, value) if args.prepare else apply(fd, args, value)
            sys.stdout.buffer.write(output)
        finally:
            os.close(fd)
        return 0
    except (ValueError, OSError, UnicodeError, RecursionError, TypeError, KeyError):
        print("Native v2 operation unresolved; preserve Before/ExpectedAfter and reconcile.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
