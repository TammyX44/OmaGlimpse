"""Hostile paste providers on a private PATH; never access the user's clipboard."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "bounded-clipboard.py"
CAP = 16384
STUB = r'''
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
root = Path(os.environ["PASTE_TEST_DIR"])
mode = (root / "mode").read_text()
with (root / "calls").open("a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
types = "--list-types" in sys.argv
if types and mode not in ("types-fast", "types-slow"):
    if mode == "wrong-kind":
        print("image/png\ntext/html\ntext/uri-list")
    elif mode == "types-invalid":
        os.write(1, b"text/plain\xff\n")
    elif mode == "types-fail":
        sys.exit(1)
    else:
        if mode == "shared-deadline":
            time.sleep(0.9)
        print("text/html\ntext/plain;charset=UTF-8\ntext/plain")
    sys.exit(0)
if mode in ("fast", "slow", "types-fast", "types-slow", "cancel", "early-exit"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-c",
        "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"])
    (root / "pids").write_text(str(os.getpid()) + " " + str(child.pid))
    if mode == "early-exit":
        sys.exit(0)  # descendant still owns stdout after the provider exits
    elif mode in ("fast", "types-fast"):
        while True:
            os.write(1, b"x" * 4096)
    elif mode in ("slow", "types-slow"):
        while True:
            os.write(1, b"x")
            time.sleep(0.1)
    else:
        time.sleep(60)
elif mode == "closed-hang":
    os.close(1)
    time.sleep(60)
elif mode == "shared-deadline":
    time.sleep(1.3)
    os.write(1, b"too late")
else:
    os.write(1, (root / "payload").read_bytes())
    if mode == "fail":
        sys.exit(7)
'''


class BoundedClipboardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omawidgets-paste-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        stub = self.root / "wl-paste"
        stub.write_text("#!" + sys.executable + "\n" + STUB)
        stub.chmod(0o700)
        self.env = os.environ.copy()
        self.env["PATH"] = self.temp.name  # No fallback to the real wl-paste.
        self.env["PASTE_TEST_DIR"] = self.temp.name
        self.configure("ok", b"hello")

    def configure(self, mode, payload=b""):
        (self.root / "mode").write_text(mode)
        (self.root / "payload").write_bytes(payload)

    def command(self, maximum=CAP):
        return [sys.executable, str(HELPER), "--max-length", str(maximum)]

    def run_helper(self, maximum=CAP):
        start = time.monotonic()
        result = subprocess.run(self.command(maximum), env=self.env,
                                capture_output=True, timeout=4)
        elapsed = time.monotonic() - start
        self.assertEqual(result.stderr, b"")
        self.assertLessEqual(len(result.stdout), 2 * CAP + 128)
        response = json.loads(result.stdout.decode("utf-8", "strict"))
        self.assertEqual(response["version"], 1)
        self.assertIs(type(response["ok"]), bool)
        self.assertEqual(response["ok"], result.returncode == 0)
        return response, elapsed

    def assert_rejected(self, mode, error, payload=b""):
        self.configure(mode, payload)
        response, elapsed = self.run_helper()
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"], error)
        self.assertNotIn("text", response)
        return elapsed

    def assert_providers_dead(self):
        pids = [int(pid) for pid in (self.root / "pids").read_text().split()]
        deadline = time.monotonic() + 0.8
        while time.monotonic() < deadline:
            live = []
            for pid in pids:
                try:
                    status = Path(f"/proc/{pid}/stat").read_text()
                    if status.rsplit(")", 1)[1].strip().split()[0] != "Z":
                        live.append(pid)
                except FileNotFoundError:
                    pass
            if not live:
                return
            time.sleep(0.01)
        self.fail(f"provider processes survived cancellation: {live}")

    def test_utf8_normalization_and_character_limit(self):
        self.configure("ok", "नमस्ते 😀\r\n東京\tA\u2028B\u2029C\x00\x1bZ".encode())
        response, _ = self.run_helper()
        self.assertEqual(response["text"], "नमस्ते 😀 東京 A B CZ")
        self.configure("ok", "😀東京é".encode())
        response, _ = self.run_helper(3)
        self.assertEqual(response["text"], "😀東京")
        response, _ = self.run_helper(0)
        self.assertEqual(response["text"], "")
        calls = (self.root / "calls").read_text()
        self.assertIn("--no-newline --type text/plain;charset=UTF-8", calls)

    def test_exact_byte_cap_and_bounded_json_escaping(self):
        self.configure("ok", b"\\" * CAP)
        response, _ = self.run_helper()
        self.assertEqual(response["text"], "\\" * CAP)
        self.assert_rejected("ok", "oversize", b"x" * (CAP + 1))
        # Character truncation must not hide a byte-cap violation.
        self.configure("ok", b"x" * (CAP + 1))
        response, _ = self.run_helper(1)
        self.assertEqual(response["error"], "oversize")

    def test_invalid_and_incomplete_utf8_fail_without_partial_text(self):
        for payload in (b"good\xff", b"good\xf0\x9f\x98", b"\xc0\xaf", b"\xed\xa0\x80"):
            with self.subTest(payload=payload):
                self.assert_rejected("ok", "invalid-utf8", payload)

    def test_wrong_kind_and_type_discovery_failure(self):
        for mode, error in (("wrong-kind", "wrong-kind"),
                            ("types-invalid", "wrong-kind"), ("types-fail", "failed")):
            with self.subTest(mode=mode):
                self.assert_rejected(mode, error)
        self.assertNotIn("--no-newline", (self.root / "calls").read_text())

    def test_failure_rejects_partial_payload_and_missing_binary(self):
        self.assert_rejected("fail", "failed", b"partial text")
        (self.root / "wl-paste").unlink()
        response, _ = self.run_helper()
        self.assertEqual(response["error"], "unavailable")

    def test_infinite_fast_streams_hit_cap_and_kill_descendants(self):
        for mode in ("fast", "types-fast"):
            with self.subTest(mode=mode):
                elapsed = self.assert_rejected(mode, "oversize")
                self.assertLess(elapsed, 1.5)
                self.assert_providers_dead()

    def test_infinite_slow_streams_hit_overall_deadline_and_kill_descendants(self):
        for mode in ("slow", "types-slow"):
            with self.subTest(mode=mode):
                elapsed = self.assert_rejected(mode, "timeout")
                self.assertGreater(elapsed, 1.8)
                self.assertLess(elapsed, 2.6)
                self.assert_providers_dead()

    def test_stdout_closed_provider_still_has_a_deadline(self):
        self.assertLess(self.assert_rejected("closed-hang", "timeout"), 2.6)

    def test_mime_and_payload_share_one_deadline(self):
        elapsed = self.assert_rejected("shared-deadline", "timeout")
        self.assertLess(elapsed, 2.6)

    def test_helper_termination_cancels_provider_group_including_forced_kill(self):
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGKILL):
            with self.subTest(signal=signum):
                (self.root / "pids").unlink(missing_ok=True)
                self.configure("cancel")
                process = subprocess.Popen(self.command(), env=self.env,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 1.5
                    while not (self.root / "pids").exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue((self.root / "pids").exists())
                    start = time.monotonic()
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=1.5)
                    self.assertEqual(stderr, b"")
                    if signum != signal.SIGKILL:
                        self.assertEqual(json.loads(stdout)["error"], "cancelled")
                    self.assert_providers_dead()
                    self.assertLess(time.monotonic() - start, 1.0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate(timeout=1)

    def test_exited_provider_leader_does_not_disarm_guardian(self):
        self.configure("early-exit")
        process = subprocess.Popen(self.command(), env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 1.5
            leader_gone = False
            while time.monotonic() < deadline:
                if (self.root / "pids").exists():
                    leader = (self.root / "pids").read_text().split()[0]
                    try:
                        stat = Path(f"/proc/{leader}/stat").read_text()
                        leader_gone = stat.rsplit(")", 1)[1].strip().split()[0] == "Z"
                    except FileNotFoundError:
                        leader_gone = True
                    if leader_gone:
                        break
                time.sleep(0.01)
            self.assertTrue(leader_gone, "provider leader must exit before killing the helper")
            # Give the guardian time to observe/reap that exit. It must remain
            # alive with parent-death cleanup armed while the child owns stdout.
            time.sleep(0.1)
            self.assertIsNone(process.poll())
            process.kill()
            stdout, stderr = process.communicate(timeout=1.5)
            self.assertEqual(stdout, b"")
            self.assertEqual(stderr, b"")
            self.assert_providers_dead()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=1)

    def test_renderer_guard_and_owned_paste_entrypoint(self):
        # A small structural guard supplements the parent's interactive native QA.
        qml = (REPO / "SafeTextField.qml").read_text()
        self.assertIn('objectName: "safeTextRenderer"', qml)
        self.assertIn("readOnly: true", qml)
        self.assertNotIn("readOnly: false", qml.replace("Accessible.readOnly: false", ""))
        self.assertNotIn(".paste(", qml)
        self.assertNotIn(".canPaste", qml)
        self.assertIn("--max-length", qml)


if __name__ == "__main__":
    unittest.main()
