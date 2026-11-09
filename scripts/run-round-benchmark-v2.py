#!/usr/bin/python3.12
"""Native v2 benchmark adapter. Never judges measurements or advances rounds.

Only the fixed Node broker owns execution, timeouts, result classification and
journals. The protected operation descriptor is provided before controller
launch; this script cannot create one or grant a user disposition.
"""
import argparse
import errno
import fcntl
import importlib.util
import os
from pathlib import Path
import selectors
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUMMARY_LIMIT = 32 * 1024
RECEIPT_LIMIT = 64 * 1024


def load(name, relative):
    path = ROOT / relative
    if path.is_symlink() or not path.is_file():
        raise ValueError("fixed native resource missing")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def program(fs, name):
    path = Path(os.environ.get(name, ""))
    fd = fs.directory(path.parent)
    try:
        value = fs.read(fd, path.name, 1024 * 1024)
        if path != path.resolve(strict=True) or value is None or not value[1] & 0o100:
            raise ValueError("fixed broker program unavailable")
    finally:
        os.close(fd)
    return path


def run_fixed(path, limit):
    child = subprocess.Popen([str(path)], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    outputs = {child.stdout.fileno(): bytearray(), child.stderr.fileno(): bytearray()}
    selector = selectors.DefaultSelector()
    try:
        for stream in [child.stdout, child.stderr]:
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map():
            for key, _ in selector.select():
                data = os.read(key.fd, 4096)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                outputs[key.fd].extend(data)
                if sum(map(len, outputs.values())) > limit:
                    raise ValueError("fixed broker display output exceeded its bound")
        code = child.wait()
        if code != 0:
            raise ValueError("fixed broker operation is unresolved")
        result = tuple(bytes(outputs[stream.fileno()]) for stream in [child.stdout, child.stderr])
        for value in result:
            value.decode("utf-8", errors="strict")
        return result
    finally:
        selector.close()
        if child.poll() is None:
            child.kill()
            child.wait()
        child.stdout.close()
        child.stderr.close()


def publish(fs, fd, name, data):
    existing = fs.read(fd, name, len(data))
    if existing is not None:
        if existing != (data, 0o600):
            raise ValueError("native publication differs from the original operation")
        return
    # An anonymous inode is never visible until the full bytes are durable.
    # A killed controller leaves no named publication debris or hardlink alias.
    handle = os.open(".", os.O_TMPFILE | os.O_WRONLY | os.O_CLOEXEC, 0o600, dir_fd=fd)
    try:
        remaining = memoryview(data)
        while remaining:
            written = os.write(handle, remaining)
            if written <= 0:
                raise OSError(errno.EIO, "short native write")
            remaining = remaining[written:]
        os.fchmod(handle, 0o600)
        os.fsync(handle)
        try:
            # dst_dir_fd selects linkat; following /proc/self/fd/N links the
            # anonymous inode exactly once and never replaces an existing name.
            os.link(f"/proc/self/fd/{handle}", name, dst_dir_fd=fd, follow_symlinks=True)
        except FileExistsError:
            if fs.read(fd, name, len(data)) != (data, 0o600):
                raise ValueError("native publication differs from the original operation")
        os.fsync(fd)
    finally:
        os.close(handle)


def execute(args):
    if os.environ.get("HUMANIZE_MANAGED_PIPELINE") != "v2" or "HUMANIZE_MANAGED_RELIABILITY_V1" in os.environ:
        raise ValueError("unambiguous protected v2 mode required")
    fs = load("fixed_native_files_v2", "scripts/apply-managed-repair-v2.py")
    decoder = load("fixed_round_decoder_v2", "scripts/validate-managed-receipt-v2.py")
    if (not fs.DECIMAL.fullmatch(args.round) or
            not args.completion and (not fs.DECIMAL.fullmatch(args.timeout) or int(args.timeout) < 1)):
        raise ValueError("invalid original round/timeout")
    project = Path(args.project_root)
    loop = Path(args.loop_dir)
    receipt_path = Path(os.environ.get("HUMANIZE_MANAGED_ROUND_RECEIPT_V2", ""))
    benchmark = program(fs, "HUMANIZE_BENCHMARK_PROGRAM_V2")
    status = program(fs, "HUMANIZE_ROUND_STATUS")
    handles = []
    try:
        for path in [project, loop, receipt_path.parent]:
            handles.append(fs.directory(path))
        project_fd, loop_fd, stage_fd = handles
        if (receipt_path.name != "round-status.json" or receipt_path.parent == loop
                or loop in receipt_path.parent.parents or receipt_path.parent == project
                or project in receipt_path.parent.parents or not fs.ULID.fullmatch(receipt_path.parent.name)
                or os.fstat(stage_fd).st_mode & 0o777 != 0o700):
            raise ValueError("round staging is not an isolated protected operation")
        fcntl.flock(stage_fd, fcntl.LOCK_EX)
        descriptor = fs.read(stage_fd, "operation.json", 16 * 1024)
        if descriptor is None:
            raise ValueError("Node did not prepare the original round operation")
        operation = fs.decode_metadata(descriptor[0])
        expected = {
            "schema": "managed-round-operation-v2", "job_id": os.environ.get("KERNAUT_WORKFLOW_JOB_ID"),
            "operation_id": receipt_path.parent.name, "round": int(args.round),
            "project_root": str(project), "loop_dir": str(loop),
            "loop_dev": os.fstat(loop_fd).st_dev, "loop_ino": os.fstat(loop_fd).st_ino,
            "benchmark_program": str(benchmark), "status_program": str(status),
            "command_sha256": os.environ.get("HUMANIZE_BENCHMARK_COMMAND_SHA256_V2"),
        }
        if (operation != expected or not expected["job_id"]
                or any(type(operation.get(key)) is not int for key in ["round", "loop_dev", "loop_ino"])):
            raise ValueError("round operation identity changed")
        if Path(args.command_file) != loop / "benchmark-command.sh":
            raise ValueError("benchmark command file differs from the fixed native path")
        command = fs.read(loop_fd, "benchmark-command.sh", 64 * 1024)
        if command is None or fs.digest(command[0])["sha256"] != operation["command_sha256"]:
            raise ValueError("original benchmark command changed")
        if args.completion:
            completion = program(fs, "HUMANIZE_COMPLETION_VALIDATOR")
            if status.name != "round-status" or completion != status.with_name("completion"):
                raise ValueError("completion callback differs from the original fixed broker directory")
            name = "completion-status.json"
            stored = fs.read(stage_fd, name, RECEIPT_LIMIT)
            if stored is not None and stored[1] != 0o600:
                raise ValueError("original completion staging mode changed")
            if stored is None:
                stdout, _ = run_fixed(completion, RECEIPT_LIMIT)
                decoder.decode(stdout, "completion")
                fs.verify_loop_inode(stage_fd, receipt_path.parent)
                fs.verify_loop_inode(loop_fd, loop)
                publish(fs, stage_fd, name, stdout)
                stored = fs.read(stage_fd, name, RECEIPT_LIMIT)
            if stored is None:
                raise ValueError("original completion staging is unavailable")
            decoder.decode(stored[0], "completion")
            fs.verify_loop_inode(stage_fd, receipt_path.parent)
            fs.verify_loop_inode(loop_fd, loop)
            # The hook sees exactly the bytes already committed by this
            # original operation. Retrying does not invoke the broker again.
            sys.stdout.buffer.write(stored[0])
            return
        receipt = fs.read(stage_fd, receipt_path.name, RECEIPT_LIMIT)
        summary = fs.read(stage_fd, "benchmark-summary.txt", SUMMARY_LIMIT + 1024)
        if any(value is not None and value[1] != 0o600 for value in [receipt, summary]):
            raise ValueError("original staging modes changed")
        if receipt is None:
            if summary is None:
                stdout, stderr = run_fixed(benchmark, SUMMARY_LIMIT)
                body = b"# Managed v2 benchmark display summary\n\n" + stdout
                if stderr:
                    body += b"\n[Broker stderr display summary]\n" + stderr
                publish(fs, stage_fd, "benchmark-summary.txt", body)
                summary = fs.read(stage_fd, "benchmark-summary.txt", SUMMARY_LIMIT + 1024)
            stdout, _ = run_fixed(status, RECEIPT_LIMIT)
            decoder.decode(stdout, "round")
            publish(fs, stage_fd, receipt_path.name, stdout)
            receipt = fs.read(stage_fd, receipt_path.name, RECEIPT_LIMIT)
        if summary is None or receipt is None:
            raise ValueError("incomplete original staging; reconcile without measurement replay")
        value = decoder.decode(receipt[0], "round")
        fs.verify_loop_inode(stage_fd, receipt_path.parent)
        fs.verify_loop_inode(loop_fd, loop)
        if value["decision"] in ("pause", "repair"):
            # A real pause or prepared owner repair must reach the main hook's
            # disposition. Neither branch publishes benchmark artifacts here.
            return
        if value["decision"] != "continue":
            raise ValueError("unknown round decision")
        stem = "round-" + args.round + "-benchmark"
        markdown = (f"# Round {args.round} Benchmark (managed v2)\n\n"
                    "The fixed Node broker retains the full original capture. The log is a bounded display summary.\n\n"
                    + "\n".join(f"- {key}: `{value[key]}`" for key in
                                ["schema", "outcome", "decision", "reason_code", "evidence_sha256"])
                    + f"\n- Display log: `{stem}.log`\n").encode()
        publish(fs, loop_fd, stem + ".log", summary[0])
        publish(fs, loop_fd, stem + ".md", markdown)
        fs.verify_loop_inode(stage_fd, receipt_path.parent)
        fs.verify_loop_inode(loop_fd, loop)
    finally:
        for fd in reversed(handles):
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    completion = sys.argv[1:2] == ["--completion"]
    parser.add_argument("--completion", action="store_true")
    names = (["project-root", "loop-dir", "round"] if completion else
             ["project-root", "loop-dir", "round", "command-file", "timeout"])
    for name in names:
        parser.add_argument("--" + name, required=True)
    arguments = sys.argv[2:] if completion else sys.argv[1:]
    if len(arguments) != len(names) * 2 or arguments[::2] != ["--" + name for name in names]:
        parser.error("exactly the original unique arguments are required")
    args = parser.parse_args()
    if completion:
        args.command_file = str(Path(args.loop_dir) / "benchmark-command.sh")
    try:
        execute(args)
    except (ValueError, OSError, RuntimeError, KeyError, TypeError, AttributeError) as error:
        print("managed v2 benchmark requires reconciliation: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
