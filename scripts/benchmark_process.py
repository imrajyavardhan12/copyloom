"""Bounded subprocess boundary for sequential, main-thread benchmark checks."""

from contextlib import contextmanager

import os
import signal
import subprocess


class CommandTimeout(TimeoutError):
    """Fixed diagnostic: never includes command arguments or paths."""


class CommandInterrupted(KeyboardInterrupt):
    """Unwinds unittest as an interrupt, rather than an ordinary test error."""

    def __init__(self, signum):
        super().__init__("Benchmark checks interrupted; workload group stopped")
        self.exit_status = 128 + signum


_command_phase = "idle"
_pending_signal = None


def _interrupt(signum, _frame):
    global _command_phase, _pending_signal
    if _command_phase in ("launching", "cleanup"):
        # Do not interrupt Popen before it returns the owned handle, or
        # interrupt cleanup before that group has been killed and reaped.
        _pending_signal = signum
    else:
        _command_phase = "cleanup"
        raise CommandInterrupted(signum)


def install_termination_handlers():
    """Own SIGINT/SIGTERM on the main thread before sequential CLI work."""
    signal.signal(signal.SIGTERM, _interrupt)
    signal.signal(signal.SIGINT, _interrupt)


def _raise_pending_signal():
    global _pending_signal
    signum, _pending_signal = _pending_signal, None
    if signum is not None:
        raise CommandInterrupted(signum)


def _stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    # Reap the orchestrator and drain its pipes before temporary-file cleanup.
    process.communicate()


@contextmanager
def owned_process(arguments, *, environment=None, cleanup=None):
    """Own one sequential main-thread CLI process; scopes must not nest.

    By default descendants must preserve its group. A nested CLI that owns
    separate sessions needs a cleanup callback that unwinds those sessions.
    """
    global _command_phase
    _command_phase = "launching"
    try:
        process = subprocess.Popen(
            arguments, env=environment, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except BaseException:
        _command_phase = "idle"
        _raise_pending_signal()
        raise
    try:
        _raise_pending_signal()
        _command_phase = "waiting"
        yield process
    finally:
        _command_phase = "cleanup"
        try:
            (cleanup or _stop_group)(process)
        finally:
            _command_phase = "idle"
            _raise_pending_signal()


def run_command(arguments, *, timeout=120):
    """Run sequential CLI work; descendants must preserve the owned group."""
    with owned_process(arguments) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise CommandTimeout("Benchmark command timed out; workload group stopped") from None
        return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
