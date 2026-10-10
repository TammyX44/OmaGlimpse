"""Run the actual QML card offscreen using only a private temporary checkout.

Requires qs, QtTest and the installed Omarchy Commons/Ui modules. Includes
real /proc sampling, deterministic subprocess fixtures, cancellation races,
and a collector which ignores TERM to exercise timeout's kill-after bound.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import json
from pathlib import Path
import signal
import sys
import time
root = Path(__file__).parent
mode = (root / "mode").read_text().strip()
counter_file = root / "counter"
counter = int(counter_file.read_text()) + 1
counter_file.write_text(str(counter))
if mode in ("slow", "hang"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30 if mode == "hang" else 0.8)
if mode == "fail":
    print("fixture failure", file=sys.stderr)
    sys.exit(1)
if mode == "invalid":
    print("{partial json")
else:
    print(json.dumps({"version": 1, "sampledAt": counter, "clockTicks": 100,
        "memoryTotalBytes": 1000, "processes": [
            {"pid": "4242", "startTime": "10", "name": "old worker",
             "cpuTicks": 1000000 + counter * 25, "rssBytes": 800},
            {"pid": "4343", "startTime": "20", "name": "new worker",
             "cpuTicks": counter * 200, "rssBytes": 200}]}))
'''

QML = r'''
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "." as Plugin

ShellRoot {
  id: root
  property bool startTests: false
  property int accepted: 0
  function path(name) { return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")) }
  Timer { interval: 100; running: true; onTriggered: root.startTests = true }
  Plugin.SamplingPolicy { id: policy; monitoringEnabled: false }
  FileView { id: modeFile; path: root.path("mode"); watchChanges: false; printErrors: false }
  FileView { id: counterFile; path: root.path("counter"); watchChanges: false; printErrors: false }
  Process {
    id: burn
    command: ["python3", "-c", "import time\nend=time.monotonic()+15\nwhile time.monotonic()<end: pass"]
  }
  FloatingWindow {
    visible: true
    implicitWidth: 350; implicitHeight: 350
    Plugin.TopProcesses {
      id: card
      samplingEnabled: false
      config: ({ widgets: { topProcesses: { refreshInterval: 60000, processCount: 2, sortBy: "cpu" } } })
      snapshotCommand: ["python3", root.path("fixture.py")]
      onPreviousSnapshotChanged: if (previousSnapshot !== null) root.accepted++
    }
    TestCase {
      name: "ProcessSampling"
      when: root.startTests
      property int passes: 0
      property int failures: 0
      function cleanup() {
        if (qtest_results.failed) {
          failures++
          console.error("PROCESS_RUNTIME_FAILED " + qtest_results.functionName)
        } else {
          passes++
          console.log("PROCESS_RUNTIME_PASSED " + qtest_results.functionName)
        }
        card.samplingEnabled = false
        if (burn.running) burn.signal(15)
      }
      function cleanupTestCase() {
        console.log("PROCESS_RUNTIME_TOTAL " + passes + " passed, " + failures + " failed")
      }
      function init() {
        card.samplingEnabled = false
        tryCompare(card, "collectionActive", false, 4000)
        card.config = { widgets: { topProcesses: { refreshInterval: 60000, processCount: 2, sortBy: "cpu" } } }
        card.samplingMultiplier = 1
        card.snapshotCommand = ["python3", root.path("fixture.py")]
        modeFile.setText("ok\n")
        wait(30)
      }
      function collectFirst() {
        card.samplingEnabled = true
        tryVerify(function() { return card.previousSnapshot !== null }, 1500)
        compare(card.collectionActive, false)
        compare(card.sampleReady, false)
      }
      function collectNext() {
        var before = root.accepted
        card.refresh()
        tryVerify(function() { return root.accepted > before }, 1500)
        compare(card.collectionActive, false)
      }
      function readCounter() {
        counterFile.reload()
        wait(50)
        return Number(counterFile.text())
      }
      function test_a_disabled_no_sampling() {
        compare(card.previousSnapshot, null)
        compare(card.processes.length, 0)
        var before = readCounter()
        card.refresh()
        wait(100)
        compare(readCounter(), before)
        compare(card.hasLoaded, false)
      }
      function test_b_first_sample_and_interval_cpu() {
        collectFirst()
        compare(card.processes.length, 2)
        compare(card.processes[0].cpu, null)
        compare(card.processes[0].mem, 80)
        collectNext()
        compare(card.sampleReady, true)
        compare(card.processes[0].pid, "4343")
        compare(card.processes[0].cpu, 200)
        compare(card.processes[1].cpu, 25)
      }
      function test_c_rank_count_changes_do_not_spawn_or_drop_baseline() {
        collectFirst()
        collectNext()
        var previous = card.previousSnapshot, before = readCounter()
        card.config = { widgets: { topProcesses: { refreshInterval: 60000, processCount: 1, sortBy: "mem" } } }
        compare(card.processes.length, 1)
        compare(card.processes[0].pid, "4242")
        compare(card.previousSnapshot, previous)
        compare(card.sampledProcesses.length, 2)
        compare(readCounter(), before)
        card.config = { widgets: { topProcesses: { refreshInterval: 60000, processCount: 2, sortBy: "cpu" } } }
        compare(card.processes[0].pid, "4343")
      }
      function test_d_pause_reset_resume_collects_immediately() {
        collectFirst()
        collectNext()
        card.samplingEnabled = false
        compare(card.previousSnapshot, null)
        compare(card.sampleReady, false)
        compare(card.processes.length, 0)
        var before = readCounter()
        card.refresh()
        wait(100)
        compare(readCounter(), before)
        collectFirst() // Does not wait for the 60-second timer.
        collectNext()
        compare(card.sampleReady, true)
        var accepted = root.accepted
        card.resetBaseline()
        compare(card.previousSnapshot, null)
        compare(card.processes.length, 0)
        tryVerify(function() { return root.accepted > accepted }, 1500)
        compare(card.sampleReady, false)
      }
      function test_e_inflight_pause_resume_discards_cancelled_snapshot() {
        modeFile.setText("slow\n")
        wait(30)
        card.samplingEnabled = true
        tryVerify(function() { return card.collectionActive && readCounter() > 0 }, 1000)
        // Let the fixture install SIGTERM ignore before cancelling it.
        wait(100)
        var before = root.accepted
        card.samplingEnabled = false
        compare(card.previousSnapshot, null)
        modeFile.setText("ok\n")
        wait(20)
        card.samplingEnabled = true
        tryVerify(function() { return root.accepted > before }, 2000)
        compare(root.accepted, before + 1)
        compare(card.sampleReady, false)
        compare(card.errorMessage, "")
        compare(card.refreshQueued, false)
      }
      function test_f_multiplier_changes_timer_and_collects_immediately() {
        collectFirst()
        compare(card.samplingInterval, 60000)
        var before = root.accepted
        card.samplingMultiplier = 3
        compare(card.samplingInterval, 180000)
        tryVerify(function() { return root.accepted > before }, 1500)
        compare(card.sampleReady, true)
        card.samplingMultiplier = 1e100
        compare(card.samplingInterval, 2147483647)
      }
      function test_g_failure_and_malformed_output_rebaseline() {
        collectFirst()
        collectNext()
        for (var i = 0; i < 2; i++) {
          modeFile.setText(i === 0 ? "fail\n" : "invalid\n")
          wait(30)
          card.refresh()
          tryVerify(function() { return card.errorMessage !== "" }, 1500)
          compare(card.previousSnapshot, null)
          compare(card.sampleReady, false)
          compare(card.processes.length, 0)
          modeFile.setText("ok\n")
          wait(30)
          collectNext()
          compare(card.sampleReady, false)
          compare(card.processes[0].cpu, null)
          compare(card.errorMessage, "")
          collectNext()
          compare(card.sampleReady, true)
        }
      }
      function test_h_bounded_collector_and_coalesced_refresh() {
        modeFile.setText("hang\n")
        wait(30)
        card.samplingEnabled = true
        tryCompare(card, "collectionActive", true, 1000)
        wait(100)
        var before = readCounter()
        for (var i = 0; i < 20; i++) card.refresh()
        compare(card.refreshQueued, true)
        modeFile.setText("ok\n")
        wait(30)
        compare(readCounter(), before)
        tryVerify(function() { return card.previousSnapshot !== null }, 4000)
        compare(readCounter(), before + 1)
        compare(card.sampleReady, false)
        compare(card.collectionActive, false)
        compare(card.refreshQueued, false)
      }
      function test_i_timer_uses_multiplier_and_pauses() {
        card.config = { widgets: { topProcesses: { refreshInterval: 500, processCount: 2, sortBy: "cpu" } } }
        card.samplingMultiplier = 2
        compare(card.samplingInterval, 1000)
        collectFirst()
        var before = readCounter()
        wait(650)
        compare(readCounter(), before)
        tryCompare(card, "sampleReady", true, 1500)
        card.samplingEnabled = false
        tryCompare(card, "collectionActive", false, 1000)
        before = readCounter()
        wait(1200)
        compare(readCounter(), before)
      }
      function test_j_shared_policy_bindings_lock_dpms_and_resume() {
        policy.observeLock("false")
        policy.observeDisplays('[{"dpmsStatus":true}]')
        policy.enabled = true
        // These are the bindings installed by Widgets.qml after Loader loads.
        card.samplingEnabled = Qt.binding(function() { return policy.samplingEnabled })
        card.samplingMultiplier = Qt.binding(function() { return policy.samplingMultiplier })
        tryVerify(function() { return card.previousSnapshot !== null }, 1500)
        compare(card.samplingMultiplier, policy.samplingMultiplier)
        compare(findChild(card, "processSamplingTimer").running, true)
        policy.observeLock("true")
        compare(card.samplingEnabled, false)
        compare(card.previousSnapshot, null)
        compare(findChild(card, "processSamplingTimer").running, false)
        var before = readCounter()
        wait(100)
        compare(readCounter(), before)
        policy.observeLock("false")
        tryVerify(function() { return card.previousSnapshot !== null }, 1500)
        compare(card.sampleReady, false)
        policy.observeDisplays('[{"dpmsStatus":false}]')
        compare(card.samplingEnabled, false)
        compare(card.previousSnapshot, null)
        policy.observeDisplays('[{"dpmsStatus":true}]')
        tryVerify(function() { return card.previousSnapshot !== null }, 1500)
        compare(card.sampleReady, false)
        policy.enabled = false
        compare(card.samplingEnabled, false)
        compare(card.previousSnapshot, null)
      }
      function test_z_real_proc_cpu_interval() {
        card.snapshotCommand = ["python3", root.path("process_snapshot.py")]
        burn.running = true
        tryVerify(function() { return Number(burn.processId) > 0 }, 1000)
        collectFirst()
        var pid = String(burn.processId)
        verify(card.sampledProcesses.some(function(p) { return p.pid === pid && p.cpu === null }))
        wait(450)
        collectNext()
        var row = card.sampledProcesses.filter(function(p) { return p.pid === pid })[0]
        verify(row !== undefined)
        verify(row.cpu > 0 && row.cpu < 150, "one busy thread should report a positive one-core CPU percentage: " + row.cpu)
        verify(row.mem >= 0)
      }
    }
  }
}
'''


class ProcessRuntimeTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("qs") and (Path(os.environ.get("OMARCHY_SHELL_DIR", "/usr/share/omarchy/shell")) / "Commons").is_dir(),
                         "requires Quickshell and the installed Omarchy QML modules")
    def test_qml_process_sampling(self):
        self.assertIsNotNone(shutil.which("qs"), "qs is required for the runtime test")
        shell = Path(os.environ.get("OMARCHY_SHELL_DIR", "/usr/share/omarchy/shell"))
        with tempfile.TemporaryDirectory(prefix="process-qml-test-") as directory:
            stage = Path(directory)
            for module in ("Commons", "Ui"):
                (stage / module).symlink_to(shell / module, target_is_directory=True)
            # Copy the assigned component plus its dependencies. The running
            # desktop and source checkout are never used as a test config.
            for name in ("TopProcesses.qml", "ProcessModel.js", "WidgetConfig.js", "process_snapshot.py",
                         "SamplingPolicy.qml", "SamplingModel.js"):
                shutil.copyfile(REPO / name, stage / name)
            (stage / "shell.qml").write_text(QML)
            (stage / "fixture.py").write_text(FIXTURE)
            (stage / "mode").write_text("ok\n")
            (stage / "counter").write_text("0")
            (stage / "runtime").mkdir(mode=0o700)
            env = os.environ.copy()
            env.update(XDG_RUNTIME_DIR=str(stage / "runtime"), QT_QPA_PLATFORM="offscreen",
                       QT_QPA_PLATFORMTHEME="basic", QT_QUICK_BACKEND="software")
            result = subprocess.run(["qs", "--no-color", "-p", str(stage / "shell.qml")],
                                    env=env, capture_output=True, text=True, timeout=35)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("PROCESS_RUNTIME_TOTAL 11 passed, 0 failed", output)
            for error in ("FAIL!", "ReferenceError", "TypeError", "Failed to load configuration",
                          "Unable to assign", "Binding loop", "PROCESS_RUNTIME_FAILED"):
                self.assertNotIn(error, output)
            print(output)


if __name__ == "__main__":
    unittest.main()
