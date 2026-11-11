"""Real filesystem publication controls; no Node execution authority or devices."""
import errno
import importlib.util
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/run-round-benchmark-v2.py"
SPEC = importlib.util.spec_from_file_location("native_publication", SCRIPT)
PUB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUB)
FS = PUB.load("native_publication_files", "scripts/apply-managed-repair-v2.py")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-publication-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def directory(self, name, mode=0o700):
        path = self.root / name
        path.mkdir(mode=mode)
        path.chmod(mode)
        fd = FS.directory(path)
        self.addCleanup(os.close, fd)
        return path, fd

    def unsupported(self):
        original = os.open

        def open_file(path, flags, *args, **kwargs):
            if flags & os.O_TMPFILE == os.O_TMPFILE:
                raise OSError(errno.EOPNOTSUPP, "anonymous inode unsupported")
            return original(path, flags, *args, **kwargs)

        return mock.patch.object(PUB.os, "open", side_effect=open_file)

    def test_actual_filesystem_stage_and_loop_publish_complete_single_link_records(self):
        for name, mode in [("stage", 0o700), ("loop", 0o750)]:
            path, fd = self.directory(name, mode)
            with mock.patch.object(PUB, "rename_no_replace", wraps=PUB.rename_no_replace) as rename:
                PUB.publish(FS, fd, "record.json", b"original complete bytes")
                print(json.dumps({"directory": str(path), "named_fallback": rename.call_count > 0}))
            self.assertEqual(FS.read(fd, "record.json"), (b"original complete bytes", 0o600))
            self.assertEqual((path / "record.json").stat().st_nlink, 1)
            self.assertEqual([item.name for item in path.iterdir()], ["record.json"])
            PUB.publish(FS, fd, "record.json", b"original complete bytes")
            with self.assertRaises(ValueError):
                PUB.publish(FS, fd, "record.json", b"changed complete bytes")

    def test_only_unsupported_open_errors_enable_the_named_path(self):
        for index, code in enumerate([errno.EINVAL, errno.EPERM, errno.EIO, errno.ENOSPC]):
            path, fd = self.directory(f"refused-{index}")
            original = os.open

            def failing_open(name, flags, *args, **kwargs):
                if flags & os.O_TMPFILE == os.O_TMPFILE:
                    raise OSError(code, "original open error")
                return original(name, flags, *args, **kwargs)

            with mock.patch.object(PUB.os, "open", side_effect=failing_open), \
                    mock.patch.object(PUB, "rename_no_replace") as rename:
                with self.assertRaises(OSError) as observed:
                    PUB.publish(FS, fd, "record.json", b"original")
                self.assertEqual(observed.exception.errno, code)
                rename.assert_not_called()
            self.assertEqual(list(path.iterdir()), [])
        path, fd = self.directory("supported-fallback")
        with self.unsupported():
            PUB.publish(FS, fd, "record.json", b"original")
        self.assertEqual(FS.read(fd, "record.json"), (b"original", 0o600))

    def test_no_replace_races_and_rename_failure_preserve_other_names(self):
        for variant in ["same", "different", "rename-error"]:
            path, fd = self.directory(variant)
            unrelated = path / ".native-publication-unrelated"
            unrelated.write_bytes(b"retain somebody else's interrupted write")
            rename = PUB.rename_no_replace

            def racing_rename(directory, source, target):
                if variant == "rename-error":
                    raise OSError(errno.EIO, "original rename failure")
                value = b"original" if variant == "same" else b"different"
                handle = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory)
                try:
                    os.write(handle, value)
                    os.fsync(handle)
                finally:
                    os.close(handle)
                rename(directory, source, target)

            with self.unsupported(), mock.patch.object(PUB, "rename_no_replace", side_effect=racing_rename):
                if variant == "same":
                    PUB.publish(FS, fd, "record.json", b"original")
                else:
                    with self.assertRaises((ValueError, OSError)):
                        PUB.publish(FS, fd, "record.json", b"original")
            expected = {unrelated.name} | ({"record.json"} if variant != "rename-error" else set())
            self.assertEqual({item.name for item in path.iterdir()}, expected)
            self.assertEqual(unrelated.read_bytes(), b"retain somebody else's interrupted write")
            if variant == "different":
                self.assertEqual(FS.read(fd, "record.json"), (b"different", 0o600))

    def test_file_and_directory_sync_failures_never_return_success(self):
        for variant in ["file", "directory"]:
            path, fd = self.directory(variant)
            sync = os.fsync

            def failing_sync(handle):
                directory = stat.S_ISDIR(os.fstat(handle).st_mode)
                if directory == (variant == "directory"):
                    raise OSError(errno.EIO, "injected durability failure")
                sync(handle)

            with self.unsupported(), mock.patch.object(PUB.os, "fsync", side_effect=failing_sync):
                with self.assertRaises(OSError):
                    PUB.publish(FS, fd, "record.json", b"original")
            if variant == "file":
                self.assertEqual(list(path.iterdir()), [])
            else:
                self.assertEqual(FS.read(fd, "record.json"), (b"original", 0o600))
                with mock.patch.object(PUB.os, "fsync", side_effect=OSError(errno.EIO, "still unsynced")):
                    with self.assertRaises(OSError):
                        PUB.publish(FS, fd, "record.json", b"original")
                with mock.patch.object(PUB.os, "fsync", wraps=os.fsync) as synced:
                    PUB.publish(FS, fd, "record.json", b"original")
                    synced.assert_called_once_with(fd)

    def test_temporary_collision_is_not_owned_or_removed_by_this_call(self):
        path, fd = self.directory("collision")
        name = ".native-publication-" + "a" * 32
        (path / name).write_bytes(b"unrelated original")
        with self.unsupported(), mock.patch.object(PUB.secrets, "token_hex", return_value="a" * 32):
            with self.assertRaises(FileExistsError):
                PUB.publish(FS, fd, "record.json", b"new bytes")
        self.assertEqual((path / name).read_bytes(), b"unrelated original")
        self.assertFalse((path / "record.json").exists())

    def test_process_exit_before_and_after_rename_does_not_forge_completion(self):
        child_code = r'''
import errno,importlib.util,os,sys
spec=importlib.util.spec_from_file_location("publisher",sys.argv[1]);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
fs=module.load("files","scripts/apply-managed-repair-v2.py")
fd=fs.directory(__import__("pathlib").Path(sys.argv[2]));original_open=os.open;original_rename=module.rename_no_replace
def open_file(path,flags,*args,**kwargs):
    if flags & os.O_TMPFILE == os.O_TMPFILE:raise OSError(errno.EOPNOTSUPP,"unsupported")
    return original_open(path,flags,*args,**kwargs)
def barrier(directory,source,target):
    if sys.argv[3]=="after":original_rename(directory,source,target)
    print("at-rename-barrier",flush=True)
    sys.stdin.buffer.read(1)
    if sys.argv[3]=="before":original_rename(directory,source,target)
module.os.open=open_file;module.rename_no_replace=barrier
try:module.publish(fs,fd,"record.json",b"original")
finally:os.close(fd)
'''
        for phase in ["before", "after"]:
            path, fd = self.directory(phase)
            child = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c", child_code,
                                      str(SCRIPT), str(path), phase], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            selector = selectors.DefaultSelector()
            try:
                selector.register(child.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(10), "original child did not reach its publication barrier")
                self.assertEqual(child.stdout.readline(), b"at-rename-barrier\n")
                child.kill()
                child.wait(timeout=10)
            finally:
                selector.close()
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)
                child.stdin.close(); child.stdout.close(); child.stderr.close()
            leftovers = {item.name: item.read_bytes() for item in path.iterdir()}
            if phase == "before":
                self.assertNotIn("record.json", leftovers)
                self.assertEqual(len(leftovers), 1)
                self.assertTrue(next(iter(leftovers)).startswith(".native-publication-"))
            else:
                self.assertEqual(leftovers, {"record.json": b"original"})
            with self.unsupported():
                PUB.publish(FS, fd, "record.json", b"original")
            self.assertEqual(FS.read(fd, "record.json"), (b"original", 0o600))
            # A later publication never adopts or sweeps a previous process's
            # named temporary. Only this fixture's own cleanup removes it.
            for name, value in leftovers.items():
                self.assertEqual((path / name).read_bytes(), value)


if __name__ == "__main__":
    unittest.main()
