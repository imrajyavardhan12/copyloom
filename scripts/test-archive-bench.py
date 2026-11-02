#!/usr/bin/env python3
"""Exercise the archive benchmark's public CLI, never private storage records."""

from contextlib import nullcontext

import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from benchmark_process import (
    CommandInterrupted, CommandTimeout, install_termination_handlers, owned_process, run_command,
)

BINARY = Path(sys.argv.pop(1)).resolve()


class ArchiveBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.corpus = self.root / "corpus.jsonl"
        # Cross both the 500-clip import batch and export page boundaries.
        with self.corpus.open("w") as output:
            for index in range(501):
                output.write(json.dumps({
                    "uuid": f"00000000-0000-7000-8000-{index:012x}",
                    "text": f"synthetic archive benchmark item {index}",
                    "capturedAtMilliseconds": 1700000000000 + index * 1000,
                }) + "\n")
        self.work = self.root / "work"

    def run_benchmark(self, *extra, records=501):
        return run_command([
            str(BINARY), "--corpus", str(self.corpus), "--records", str(records),
            "--workdir", str(self.work), "--commit", "smoke-test", *extra,
        ])

    def stop_cli_owner(self, caller):
        # Nested owners must unwind their independent sessions before the
        # caller's own group is forcibly stopped as a bounded fallback.
        if caller.poll() is None:
            caller.terminate()
        try:
            caller.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(caller.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            caller.communicate()

    def test_timeout_stops_descendants_without_echoing_command_paths(self):
        pidfile = self.root / "descendant.pid"
        helper = (
            "import subprocess, sys, time; from pathlib import Path; "
            "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
            "Path(sys.argv[1]).write_text(str(child.pid)); time.sleep(60)"
        )
        child = None
        needs_cleanup = True
        try:
            with self.assertRaises(CommandTimeout) as caught:
                run_command([sys.executable, "-c", helper, str(pidfile)], timeout=2)
            self.assertTrue(pidfile.exists(), "synthetic descendant did not initialize")
            child = int(pidfile.read_text())
            state = subprocess.run(
                ["/bin/ps", "-p", str(child), "-o", "stat="], capture_output=True,
                timeout=10,
            ).stdout.strip()
            needs_cleanup = bool(state and not state.startswith(b"Z"))
            self.assertFalse(needs_cleanup, "a workload descendant survived the command timeout")
            self.assertFalse(str(self.root) in str(caught.exception),
                             "timeout diagnostics exposed command paths")
        finally:
            # Also clean up the intentionally failing pre-fix regression.
            if child is None and pidfile.exists():
                child = int(pidfile.read_text())
            if child is not None and needs_cleanup:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_interrupted_acquisition_does_not_orphan_its_new_group(self):
        # Independent observation precedes normal PID publication. In the
        # outer-signal cases, only graceful caller teardown releases that
        # publication barrier; SIGKILL would strand the separately owned child.
        caller_source = """
import json, os, signal, subprocess, sys, time
from pathlib import Path
from benchmark_process import CommandInterrupted, install_termination_handlers, owned_process
original_launch = subprocess.Popen
pidfile, observed = Path(sys.argv[1]), Path(sys.argv[2])
outer_signal = int(sys.argv[3])
released = pidfile.with_suffix('.released')

def interrupted_launch(*arguments, **options):
    process = original_launch(*arguments, **options)
    temporary = observed.with_suffix('.tmp')
    temporary.write_text(json.dumps({'pid':process.pid}))
    temporary.replace(observed)
    if outer_signal:
        os.kill(os.getppid(), outer_signal)
        deadline = time.monotonic() + 10
        while not released.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not released.exists():
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise RuntimeError('nested caller did not receive teardown')
    temporary = pidfile.with_suffix('.tmp')
    temporary.write_text(json.dumps({'pid':process.pid}))
    temporary.replace(pidfile)
    os.kill(os.getpid(), signal.SIGTERM)
    return process

subprocess.Popen = interrupted_launch
install_termination_handlers()
if outer_signal:
    previous = signal.getsignal(signal.SIGTERM)
    def release_on_termination(signum, frame):
        released.touch()
        previous(signum, frame)
    signal.signal(signal.SIGTERM, release_on_termination)
try:
    with owned_process([sys.executable, '-c', 'import time; time.sleep(60)']):
        raise RuntimeError('acquisition interruption was lost')
except CommandInterrupted as interrupted:
    raise SystemExit(interrupted.exit_status)
"""
        environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent))
        for outer_signal in (0, signal.SIGTERM, signal.SIGINT):
            with self.subTest(outer_signal=outer_signal):
                pidfile = self.root / f"acquired-{outer_signal}.json"
                observed = self.root / f"observed-{outer_signal}.json"
                child_pid = None
                child_stopped = False
                child_alive_before_rescue = None

                def cleanup_caller(caller):
                    nonlocal child_pid, child_alive_before_rescue
                    try:
                        self.stop_cli_owner(caller)
                    finally:
                        if observed.exists():
                            child_pid = json.loads(observed.read_text())["pid"]
                            try:
                                state = subprocess.run(
                                    ["/bin/ps", "-p", str(child_pid), "-o", "stat="],
                                    capture_output=True, timeout=10,
                                ).stdout.strip()
                                child_alive_before_rescue = bool(state and not state.startswith(b"Z"))
                            finally:
                                try:
                                    os.killpg(child_pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass

                expectation = self.assertRaises(CommandInterrupted) if outer_signal else nullcontext()
                try:
                    with expectation as caught:
                        with owned_process(
                            [sys.executable, "-c", caller_source, str(pidfile),
                             str(observed), str(outer_signal)],
                            environment=environment, cleanup=cleanup_caller,
                        ) as caller:
                            _, stderr = caller.communicate(timeout=10)
                    self.assertTrue(observed.exists(), "synthetic acquisition did not initialize")
                    child_pid = json.loads(observed.read_text())["pid"]
                    state = subprocess.run(
                        ["/bin/ps", "-p", str(child_pid), "-o", "stat="],
                        capture_output=True, timeout=10,
                    ).stdout.strip()
                    child_stopped = not bool(state and not state.startswith(b"Z"))
                    self.assertTrue(child_stopped, "fixture rescue left its child alive")
                    self.assertIsNotNone(child_alive_before_rescue,
                                         "acquisition liveness was not observed before rescue")
                    self.assertFalse(child_alive_before_rescue,
                                     "interrupted acquisition orphaned its new group")
                    self.assertEqual(caller.returncode, 128 + signal.SIGTERM)
                    if outer_signal:
                        self.assertEqual(caught.exception.exit_status, 128 + outer_signal)
                    else:
                        self.assertFalse(str(self.root).encode() in stderr,
                                         "acquisition diagnostics exposed command paths")
                finally:
                    # Independent PID observation keeps a failing regression
                    # self-cleaning even when normal publication never happened.
                    if child_pid is None and observed.exists():
                        child_pid = json.loads(observed.read_text())["pid"]
                    if child_pid is not None and not child_stopped:
                        try:
                            os.killpg(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_cli_signals_stop_its_owned_workload(self):
        helper = self.root / "signal-helper"
        helper.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, subprocess, sys, time\n"
            "from pathlib import Path\n"
            "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            "target=Path(os.environ['COPYLOOM_SIGNAL_PIDFILE'])\n"
            "temporary=target.with_suffix('.tmp')\n"
            "temporary.write_text(json.dumps("
            "{'parent':os.getpid(),'group':os.getpgrp(),'child':child.pid}))\n"
            "temporary.replace(target)\n"
            "time.sleep(60)\n"
        )
        helper.chmod(0o700)
        for sent_signal in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sent_signal):
                pidfile = self.root / f"signal-{sent_signal}.json"
                environment = dict(os.environ, COPYLOOM_SIGNAL_PIDFILE=str(pidfile))
                workload = None
                workload_stopped = False

                def cleanup_caller(caller):
                    nonlocal workload
                    self.stop_cli_owner(caller)
                    if workload is None and pidfile.exists():
                        workload = json.loads(pidfile.read_text())
                    if workload is not None and not workload_stopped:
                        try:
                            os.killpg(workload["group"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass

                with owned_process([
                    sys.executable, str(Path(__file__).resolve()), str(helper),
                    "ArchiveBenchmarkTests.test_round_trip_and_reimport_report",
                ], environment=environment, cleanup=cleanup_caller) as caller:
                    deadline = time.monotonic() + 10
                    while not pidfile.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(pidfile.exists(), "synthetic workload did not initialize")
                    workload = json.loads(pidfile.read_text())
                    caller.send_signal(sent_signal)
                    _, stderr = caller.communicate(timeout=10)
                    for pid in (workload["parent"], workload["child"]):
                        state = subprocess.run(
                            ["/bin/ps", "-p", str(pid), "-o", "stat="],
                            capture_output=True, timeout=10,
                        ).stdout.strip()
                        self.assertFalse(state and not state.startswith(b"Z"),
                                         "CLI termination orphaned an owned workload")
                    workload_stopped = True
                    self.assertEqual(caller.returncode, 128 + sent_signal)
                    self.assertFalse(str(self.root).encode() in stderr,
                                     "termination diagnostics exposed command paths")

    def test_round_trip_and_reimport_report(self):
        result = self.run_benchmark()
        self.assertEqual(result.returncode, 0, "benchmark must complete")
        report = json.loads((self.work / "report.json").read_text())
        self.assertEqual(report["textRecords"], 501)
        self.assertEqual(report["imageRecords"], 0)
        self.assertEqual(report["commit"], "smoke-test")
        self.assertIn("Swift", report["swiftVersion"])
        self.assertIn("Xcode", report["xcodeVersion"])
        self.assertTrue(report["roundTripVerified"])
        self.assertTrue(report["reimportContentUnchanged"])
        # Validate public archive artifacts independently of the report flags.
        for name in ("clips.jsonl", "library.json"):
            original = hashlib.sha256((self.work / "original" / name).read_bytes()).digest()
            for stage in ("roundtrip", "reimportcheck"):
                actual = hashlib.sha256((self.work / stage / name).read_bytes()).digest()
                self.assertTrue(actual == original, "round-trip archive content changed")
        phases = {phase["name"]: phase for phase in report["phases"]}
        self.assertEqual(set(phases), {"export", "verify", "plan", "apply", "reimport"})
        self.assertEqual(phases["export"]["clipsAfter"], 501)
        self.assertEqual(phases["plan"]["clipsAfter"], 0)
        self.assertEqual(phases["plan"]["added"], 501)
        self.assertEqual(phases["apply"]["added"], 501)
        self.assertEqual(phases["reimport"]["added"], 0)
        self.assertEqual(phases["reimport"]["merged"], 501)
        self.assertEqual(len({phase["processID"] for phase in phases.values()}), 5)
        self.assertEqual({phase["processGroupID"] for phase in phases.values()},
                         {report["processGroupID"]}, "native workers escaped owned cancellation group")
        for phase in phases.values():
            self.assertGreater(phase["seconds"], 0)
            self.assertGreater(phase["peakRSSBytes"], 0)
            self.assertGreaterEqual(phase["verificationSeconds"], 0)
            self.assertEqual(phase["rejected"], 0)
            self.assertGreater(phase["databaseBytes"], 0)
            self.assertGreaterEqual(phase["walBytes"], 0)
            self.assertGreater(phase["archiveBytes"], 0)

    def test_duplicate_input_texts_still_measure_the_requested_live_scale(self):
        records = [json.loads(line) for line in self.corpus.read_text().splitlines()[:2]]
        records[1]["text"] = records[0]["text"]
        self.corpus.write_text("".join(json.dumps(record) + "\n" for record in records))
        result = self.run_benchmark(records=2)
        self.assertEqual(result.returncode, 0, "scale must count live clips, not input lines")
        report = json.loads((self.work / "report.json").read_text())
        self.assertEqual(report["setup"]["textUniquenessSuffix"], "archive-sequence-v1")
        self.assertEqual(report["phases"][0]["clipsAfter"], 2)

    def verification_peak(self, name, records):
        work = self.root / name
        work.mkdir()
        (work / ".copyloom-archive-bench").write_text("synthetic-only\n")
        (work / "target").mkdir()
        archive = work / "original"
        archive.mkdir()
        # A valid logical archive with long synthetic lines. Only verification
        # runs: no JSON clip decoding, privacy classification or import writes.
        text = "z" * (512 * 1024)
        with (archive / "clips.jsonl").open("w") as output:
            for index in range(records):
                output.write(json.dumps({
                    "uuid": f"00000000-0000-7000-8000-{index:012x}", "kind": "text",
                    "createdAt": "2026-10-30T00:00:00.000Z",
                    "lastSeenAt": "2026-10-30T00:00:00.000Z", "lastUsedAt": None,
                    "copyCount": 1, "useCount": 0, "isPinned": False, "isFavorite": False,
                    "representations": [{"uti": "public.utf8-plain-text", "text": text}],
                    "sources": [], "tags": [],
                }) + "\n")
        (archive / "library.json").write_text(
            '{"collections":[],"tags":[],"savedQueries":[]}'
        )
        files = []
        for filename in ("clips.jsonl", "library.json"):
            digest = hashlib.sha256()
            with (archive / filename).open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
            files.append({"path": filename, "bytes": (archive / filename).stat().st_size,
                          "sha256": digest.hexdigest()})
        archive_digest = hashlib.sha256("".join(
            f"{entry['path']}\0{entry['sha256']}\n"
            for entry in sorted(files, key=lambda entry: entry["path"])
        ).encode()).hexdigest()
        manifest = {
            "format": "io.github.imrajyavardhan12.copyloom.archive", "formatVersion": 1,
            "createdAt": "2026-10-31T00:00:00.000Z",
            "createdBy": {"app": "Copyloom", "appVersion": "test", "schemaVersion": 6},
            "counts": {"clips": records, "attachments": 0, "collections": 0,
                       "tags": 0, "savedQueries": 0},
            "skipped": {"sensitive": 0, "quarantinedImage": 0, "missingAttachment": 0},
            "files": files, "archiveDigest": archive_digest,
        }
        (archive / "manifest.json").write_text(json.dumps(manifest))
        result = run_command([
            str(BINARY), "--phase", "verify", "--corpus", str(self.corpus),
            "--records", str(records), "--workdir", str(work),
        ])
        self.assertEqual(result.returncode, 0, "synthetic archive must verify")
        return json.loads((work / "verify.json").read_text())["peakRSSBytes"]

    def test_verification_memory_does_not_retain_the_whole_file(self):
        small = self.verification_peak("small", 2)
        large = self.verification_peak("large", 256)
        # Compare fresh processes on this machine, with generous headroom:
        # streaming a further 127 MiB must not retain another 64 MiB of reads.
        self.assertLess(large - small, 64 * 1024 * 1024,
                        "verification retained archive-sized temporary buffers")

    def test_existing_work_directory_is_untouched(self):
        self.work.mkdir()
        sentinel = self.work / "keep.txt"
        sentinel.write_text("untouched")
        result = self.run_benchmark()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "untouched")
        self.assertEqual(len(list(self.work.iterdir())), 1)
        self.assertNotIn(str(self.work).encode(), result.stderr)

    def test_wrong_corpus_count_cannot_publish_a_report(self):
        result = self.run_benchmark(records=500)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "report.json").exists())
        self.assertNotIn(str(self.corpus).encode(), result.stderr)
        self.assertIn(b"corpus_count", result.stderr)

    def test_privacy_refusal_is_content_free(self):
        planted = "PASSWORD=synthetic-benchmark-only-credential"
        records = [json.loads(line) for line in self.corpus.read_text().splitlines()]
        records[0]["text"] = planted
        self.corpus.write_text("".join(json.dumps(record) + "\n" for record in records))
        result = self.run_benchmark()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "report.json").exists())
        self.assertNotIn(planted.encode(), result.stdout + result.stderr)
        self.assertNotIn(str(self.corpus).encode(), result.stdout + result.stderr)
        self.assertIn(b"corpus_privacy_gate", result.stderr)


if __name__ == "__main__":
    install_termination_handlers()
    try:
        unittest.main()
    except CommandInterrupted as interrupted:
        print(str(interrupted), file=sys.stderr)
        raise SystemExit(interrupted.exit_status)
