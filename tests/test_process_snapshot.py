"""Unit tests and a real /proc subprocess check for the bounded collector."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "process_snapshot.py"
spec = importlib.util.spec_from_file_location("process_snapshot", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def stat(pid=42, name="worker", user=100, system=20, start=300, rss=8):
    fields = ["S"] + ["0"] * 21
    for index, value in ((11, user), (12, system), (19, start), (21, rss)):
        fields[index] = str(value)
    return f"{pid} ({name}) " + " ".join(fields)


class SnapshotTest(unittest.TestCase):
    def test_stat_fields_and_parentheses_in_name(self):
        result = helper.parse_stat(stat(name="a ) name (x)\n"), 42, 4096)
        self.assertEqual(result, {"pid": "42", "startTime": "300", "name": "a ) name (x) ",
                                  "cpuTicks": 120, "rssBytes": 32768})
        # Huge identity values stay strings for lossless PID reuse checks in JS.
        self.assertEqual(helper.parse_stat(stat(start=99999999999999999999), 42, 4096)["startTime"],
                         "99999999999999999999")

    def test_stat_rejects_wrong_pid_truncation_negative_and_nonnumeric_counters(self):
        for raw in ("", "42 (bad)", stat(pid=43), stat(user=-1), stat(system="bad"), stat(start=-1)):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                helper.parse_stat(raw, 42, 4096)
        self.assertEqual(helper.parse_stat(stat(rss=-1), 42, 4096)["rssBytes"], 0)

    def test_collect_skips_exited_unreadable_and_malformed_pids(self):
        with tempfile.TemporaryDirectory(prefix="process-proc-test-") as directory:
            root = Path(directory)
            (root / "meminfo").write_text("MemTotal: 1000 kB\nMemFree: 500 kB\n")
            for pid in (42, 43, 44):
                (root / str(pid)).mkdir()
            (root / "42" / "stat").write_text(stat())
            (root / "43" / "stat").write_text("truncated")
            (root / "self").mkdir()
            with patch.object(helper.os, "sysconf", side_effect=[100, 4096]):
                result = helper.collect(root)
            self.assertEqual(result["memoryTotalBytes"], 1000 * 1024)
            self.assertEqual(result["clockTicks"], 100)
            self.assertEqual([p["pid"] for p in result["processes"]], ["42"])
            (root / "meminfo").write_text("MemTotal: 0 kB\n")
            with self.assertRaises(ValueError):
                helper.collect(root)

    def test_record_count_time_and_output_bounds_fail_without_partial_output(self):
        with tempfile.TemporaryDirectory(prefix="process-limit-test-") as directory:
            root = Path(directory)
            (root / "meminfo").write_text("MemTotal: 1000 kB\n")
            (root / "42").mkdir()
            (root / "42" / "stat").write_text(stat())
            with patch.object(helper, "MAX_PROCESSES", 0), self.assertRaisesRegex(ValueError, "process limit"):
                helper.collect(root)
            with patch.object(helper.time, "monotonic", side_effect=[1.0, 4.0]), self.assertRaisesRegex(ValueError, "time limit"):
                helper.collect(root)
            with patch.object(helper, "MAX_OUTPUT_BYTES", 10), self.assertRaisesRegex(ValueError, "output limit"):
                helper.encode_snapshot({"processes": ["x" * 30]})
            with patch.object(helper, "MAX_FILE_BYTES", 10), self.assertRaisesRegex(ValueError, "size limit"):
                helper.read_bounded(root / "42" / "stat")
        with patch.object(helper, "collect", side_effect=ValueError("deadline")), \
                patch("sys.stdout") as stdout, patch("sys.stderr") as stderr:
            self.assertEqual(helper.main(), 1)
            stdout.write.assert_not_called()
            self.assertTrue(stderr.write.called)

    def test_real_helper_reads_this_pid_and_uses_monotonic_time(self):
        results = []
        for _ in range(2):
            completed = subprocess.run(["timeout", "--kill-after=0.2s", "3s", "python3", str(HELPER)],
                                       capture_output=True, text=True, timeout=4, check=True)
            self.assertLess(len(completed.stdout), helper.MAX_OUTPUT_BYTES)
            result = json.loads(completed.stdout)
            self.assertEqual(result["clockTicks"], os.sysconf("SC_CLK_TCK"))
            self.assertGreater(result["memoryTotalBytes"], 0)
            process = next(p for p in result["processes"] if p["pid"] == str(os.getpid()))
            results.append((result, process))
        self.assertGreater(results[1][0]["sampledAt"], results[0][0]["sampledAt"])
        self.assertEqual(results[0][1]["startTime"], results[1][1]["startTime"])
        self.assertGreaterEqual(results[1][1]["cpuTicks"], results[0][1]["cpuTicks"])


if __name__ == "__main__":
    unittest.main()
