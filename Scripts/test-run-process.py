#!/usr/bin/env python3
"""Portable integration tests for the production C process runner."""
import ctypes as C
import errno
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'Scripts/Fixtures/Run/process.py'
BUILD = tempfile.TemporaryDirectory(prefix='compeditor-run-tests-')
LIB = Path(BUILD.name) / ('runner.dylib' if sys.platform == 'darwin' else 'runner.so')
subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', '-shared', '-fPIC', str(ROOT / 'CotEditor/Sources/Run/RunProcess.c'), '-o', str(LIB)], check=True)
lib = C.CDLL(str(LIB))
def configure(lib):
    lib.ce_run_create.restype = C.c_void_p
    lib.ce_run_execute.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(C.c_char_p), C.POINTER(C.c_char_p), C.c_char_p, C.c_void_p, C.c_size_t, C.c_int, C.POINTER(C.c_int)]
    lib.ce_run_stop.argtypes = lib.ce_run_destroy.argtypes = lib.ce_run_eof.argtypes = [C.c_void_p]
    lib.ce_run_send.argtypes = [C.c_void_p, C.c_void_p, C.c_size_t]
    lib.ce_run_send.restype = C.c_long
    lib.ce_run_copy.argtypes = [C.c_void_p, C.c_int, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]
    lib.ce_run_copy.restype = C.c_size_t

configure(lib)

class Run:
    def __init__(self, mode, data=b'', interactive=False, executable=None, cwd=None):
        self.owner = lib.ce_run_create()
        assert self.owner
        self.code = self.status = None
        self.executable = executable or sys.executable
        self.args = (C.c_char_p * 4)(os.fsencode(self.executable), os.fsencode(FIXTURE), mode.encode(), None)
        self.env = (C.c_char_p * 2)(b'PYTHONIOENCODING=utf-8', None)
        self.data = C.create_string_buffer(data)
        self.cwd = os.fsencode(cwd or ROOT)
        def execute():
            status = C.c_int()
            self.code = lib.ce_run_execute(self.owner, os.fsencode(self.executable), self.args, self.env, self.cwd, self.data, len(data), interactive, C.byref(status))
            self.status = status.value
        self.thread = threading.Thread(target=execute, daemon=True)
    def start(self): self.thread.start(); return self
    def wait(self, timeout=4):
        self.thread.join(timeout)
        if self.thread.is_alive():
            lib.ce_run_stop(self.owner); self.thread.join(2)
            raise AssertionError('runner exceeded deadline')
        return self
    def output(self, stream=0):
        data = C.create_string_buffer(10 * 1024 * 1024)
        omitted = C.c_size_t()
        n = lib.ce_run_copy(self.owner, stream, data, len(data), C.byref(omitted))
        return data.raw[:n], omitted.value
    def wait_for_pid(self, timeout=4):
        # Fixtures print only after SIGTERM is ignored. The deadline concerns
        # startup readiness, and is separate from the bounded Stop assertion.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            prefix = C.create_string_buffer(64)
            count = lib.ce_run_copy(self.owner, 0, prefix, len(prefix), None)
            first = prefix.raw[:count].splitlines()
            if first and first[0].isdigit(): return int(first[0])
            if not self.thread.is_alive(): break
            time.sleep(.005)
        raise AssertionError('fixture did not acknowledge installed signal handler')
    def close(self):
        if self.thread.is_alive(): lib.ce_run_stop(self.owner); self.wait()
        lib.ce_run_destroy(self.owner)
    def __enter__(self): return self
    def __exit__(self, *args): self.close()

def alive(pid):
    # Linux zombies are exited processes awaiting the container init's reaper.
    stat = Path(f'/proc/{pid}/stat')
    if stat.exists() and stat.read_text().split()[2] == 'Z': return False
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False

class ProcessTests(unittest.TestCase):
    def test_exact_stdin_and_eof(self):
        for data in (b'', '日本語😀 without newline'.encode(), b'x' * (2 * 1024 * 1024)):
            with Run('echo', data).start() as run:
                # Large I/O gets a separate bounded budget from Stop's strict
                # two-second deadline. Mac QA measured 4.402 s with the old
                # polling cadence; scheduling variance is not an EOF failure.
                run.wait(10 if len(data) >= 1024 * 1024 else 4)
                self.assertEqual(run.output(), (data, 0)); self.assertEqual(run.status, 0)
    def test_parallel_streams_and_split_utf8(self):
        with Run('streams').start() as run:
            run.wait(); self.assertEqual(run.output()[0].decode(), '日😀'); self.assertEqual(run.output(1)[0].decode(), '警告'); self.assertEqual(run.status, 0)
    def test_invalid_bytes_preserved(self):
        with Run('invalid').start() as run:
            run.wait(); self.assertEqual(run.output()[0], b'a\xffb')
    def test_both_streams_flood_retention_and_drain(self):
        with Run('flood').start() as run:
            run.wait()
            for stream in (0, 1):
                data, omitted = run.output(stream)
                self.assertEqual(len(data), 10 * 1024 * 1024); self.assertEqual(omitted, 2 * 1024 * 1024)
            self.assertEqual(run.status, 0)
    def test_exit_signal_launch_failure(self):
        with Run('exit').start() as run:
            run.wait(); self.assertEqual(os.waitstatus_to_exitcode(run.status), 7)
        with Run('signal').start() as run:
            run.wait(); self.assertEqual(os.waitstatus_to_exitcode(run.status), -signal.SIGUSR1)
        with Run('echo', executable='/no/such/python').start() as run:
            run.wait(); self.assertEqual(run.code, errno.ENOENT)
    def test_early_close_and_repeated_eof(self):
        with Run('early-close', b'x' * (2 * 1024 * 1024), True).start() as run:
            time.sleep(.1)
            lib.ce_run_eof(run.owner); lib.ce_run_eof(run.owner)
            self.assertEqual(lib.ce_run_send(run.owner, b'x', 1), -errno.EPIPE)
            run.wait(); self.assertEqual(run.status, 0)
    def test_stop_before_spawn(self):
        with Run('echo') as run:
            lib.ce_run_stop(run.owner); run.start().wait(); self.assertEqual(run.code, errno.ECANCELED)
    def test_stop_during_spawn_race(self):
        for _ in range(20):
            with Run('ignore-term').start() as run:
                lib.ce_run_stop(run.owner); run.wait(2)
                self.assertIn(run.code, (0, errno.ECANCELED))
    def test_stop_backpressure_and_term_ignore(self):
        with Run('backpressure', b'x' * (4 * 1024 * 1024), True).start() as run:
            run.wait_for_pid()
            started = time.monotonic(); lib.ce_run_stop(run.owner); run.wait(2)
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertEqual(os.waitstatus_to_exitcode(run.status), -signal.SIGKILL)
            self.assertFalse(any(alive(int(pid)) for pid in run.output()[0].split()))
    def test_parent_exits_first_descendants_are_cleaned(self):
        with Run('descendants').start() as run:
            run.wait(2); pids = list(map(int, run.output()[0].split())); self.assertGreaterEqual(len(pids), 3)
            self.assertFalse(any(alive(pid) for pid in pids), pids)
    def test_interactive_and_eof(self):
        with Run('echo', b'initial', True).start() as run:
            time.sleep(.1); self.assertEqual(lib.ce_run_send(run.owner, b' next\n', 6), 6)
            lib.ce_run_eof(run.owner); lib.ce_run_eof(run.owner); run.wait()
            self.assertEqual(run.output()[0], b'initial next\n')
    def test_escalation_uses_injected_monotonic_clock(self):
        global lib
        original = lib
        clock_lib = Path(BUILD.name) / ('clock.dylib' if sys.platform == 'darwin' else 'clock.so')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', '-shared', '-fPIC', '-DCE_RUN_TEST_CLOCK',
            str(ROOT / 'CotEditor/Sources/Run/RunProcess.c'), str(ROOT / 'Scripts/Fixtures/Run/clock.c'), '-o', str(clock_lib)], check=True)
        lib = C.CDLL(str(clock_lib)); configure(lib)
        lib.ce_run_test_advance.argtypes = [C.c_long]
        lib.ce_run_test_reads.restype = C.c_long
        try:
            with Run('ignore-term').start() as run:
                run.wait_for_pid()
                deadline = time.monotonic() + 2
                lib.ce_run_stop(run.owner)
                while not lib.ce_run_test_reads() and time.monotonic() < deadline: time.sleep(.01)
                self.assertGreater(lib.ce_run_test_reads(), 0)
                lib.ce_run_test_advance(299)
                run.thread.join(.05); self.assertTrue(run.thread.is_alive(), 'escalated before grace period')
                lib.ce_run_test_advance(1)
                run.wait(2)
                self.assertEqual(os.waitstatus_to_exitcode(run.status), -signal.SIGKILL)
        finally: lib = original
    def test_concurrent_fallback_creation_cannot_leak_stdin_endpoints(self):
        global lib
        original = lib
        fallback = Path(BUILD.name) / ('fallback.dylib' if sys.platform == 'darwin' else 'fallback.so')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', '-shared', '-fPIC',
            '-DCE_RUN_FORCE_FD_FALLBACK', '-DCE_RUN_TEST_FD_WINDOW', str(ROOT / 'CotEditor/Sources/Run/RunProcess.c'),
            str(ROOT / 'Scripts/Fixtures/Run/fd-window.c'), '-o', str(fallback)], check=True)
        lib = C.CDLL(str(fallback)); configure(lib)
        lib.ce_run_test_fd_arrivals.restype = C.c_int
        try:
            with Run('echo', b'exact EOF').start() as first:
                deadline = time.monotonic() + 2
                while lib.ce_run_test_fd_arrivals() == 0 and time.monotonic() < deadline: time.sleep(.005)
                with Run('ignore-term').start() as second:
                    try:
                        time.sleep(.05)
                        self.assertEqual(lib.ce_run_test_fd_arrivals(), 1, 'other runner crossed the unflagged-descriptor window')
                    finally: lib.ce_run_test_release_fds()
                    # The long-running second child must not hold first's stdin
                    # peer alive: first observes EOF and finishes independently.
                    first.wait(2)
                    self.assertEqual(first.output()[0], b'exact EOF')
                    self.assertTrue(second.thread.is_alive())
                    lib.ce_run_stop(second.owner); second.wait(2)
        finally:
            lib.ce_run_test_release_fds()
            lib = original

    def test_unicode_space_cwd(self):
        with tempfile.TemporaryDirectory(prefix='実行 space ') as directory:
            with Run('echo', b'ok', cwd=directory).start() as run:
                run.wait(); self.assertEqual(run.output()[0], b'ok')

if __name__ == '__main__': unittest.main(verbosity=2)
