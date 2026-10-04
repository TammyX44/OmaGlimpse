import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "." as Plugin
import "WidgetConfig.js" as Config

// Staged by run-gpu-qml-tests.sh so qs.Commons and qs.Ui resolve to the
// installed shell, while every plugin component comes from this checkout.
ShellRoot {
  id: root
  property var testConfig: Config.defaultConfig()
  property bool startTests: false
  Timer { interval: 200; running: true; onTriggered: root.startTests = true }
  property var fixture: [
    { id: "0000:00:02.0", name: "Intel UHD Graphics", kind: "Integrated GPU", vendor: "intel", utilization: 12, temp: 42, status: "Ready" },
    { id: "0000:01:00.0", name: "NVIDIA GeForce RTX 3050", kind: "Discrete GPU", vendor: "nvidia", utilization: 35, temp: 53, status: "Ready" }
  ]
  Item { id: readings; property var devices: root.fixture; property bool discoveryReady: true }
  Plugin.GpuMonitor {
    id: collector
    config: ({ widgets: { systemMonitor: { enabled: false }, temperature: { enabled: false } } })
    discoveryCommand: ["sh", decodeURIComponent(Qt.resolvedUrl("gpu-test-discover.sh").toString().replace(/^file:\/\//, ""))]
  }
  FileView {
    id: fixturePower
    path: decodeURIComponent(Qt.resolvedUrl("fixtures/power").toString().replace(/^file:\/\//, ""))
    watchChanges: false
    printErrors: false
  }

  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 650; implicitHeight: 310
    color: "#13151b"
    Plugin.SystemMonitor {
      id: card
      x: 25; y: 25
      config: root.testConfig
      gpuMonitor: readings
      onGpuSelected: function(deviceId) {
        var cfg = Config.deepMerge({}, root.testConfig)
        cfg.widgets.systemMonitor.gpuDevice = deviceId
        root.testConfig = cfg
      }
    }
    Plugin.Temperature {
      id: temperature
      x: 400; y: 25
      config: root.testConfig
      gpuMonitor: readings
    }
    TestCase {
      name: "GpuInteraction"
      when: root.startTests
      property var slot
      property int passes: 0
      property int failures: 0
      function cleanup() {
        if (qtest_results.failed) {
          failures++
          console.error("GPU_UI_FAILED " + qtest_results.functionName)
        } else {
          passes++
          console.log("GPU_UI_PASSED " + qtest_results.functionName)
        }
      }
      function cleanupTestCase() {
        console.log("GPU_UI_TOTAL " + passes + " passed, " + failures + " failed")
      }
      function test_collector_backends_and_demand() {
        collector.config = { widgets: { systemMonitor: { enabled: true, refreshInterval: 500 }, temperature: { enabled: false } } }
        tryVerify(function() {
          return collector.devices.length === 3 && collector.devices.every(function(device) { return device.status === "Ready" })
        }, 5000)
        compare(collector.devices[0].utilization, 11)
        compare(collector.devices[1].utilization, 32)
        compare(collector.devices[1].temp, 53)
        compare(collector.devices[2].utilization, 27)
        compare(collector.devices[2].temp, 40.5)
        compare(collector.devices[2].memUsed, 2)
        fixturePower.setText("suspended\n")
        tryVerify(function() { return collector.devices.every(function(device) { return device.status === "Sleeping" && device.utilization === null }) }, 3000)
        compare(collector.devices.length, 3)
        fixturePower.setText("active\n")
        tryVerify(function() { return collector.devices.every(function(device) { return device.status === "Ready" }) }, 3000)
        collector.config = { widgets: { systemMonitor: { enabled: false }, temperature: { enabled: true, refreshInterval: 1000, sensors: ["gpu"] } } }
        compare(collector.pollingEnabled, true)
        compare(collector.refreshInterval, 1000)
        // The Intel stream must restart when the requested sample interval changes.
        tryVerify(function() { return collector.devices[0].utilization === 11 }, 3000)
        collector.config = { widgets: { systemMonitor: { enabled: false }, temperature: { enabled: true, sensors: ["cpu"] } } }
        compare(collector.pollingEnabled, false)
        wait(30)
        compare(collector.nvidiaSamples, {})
      }
      function init() {
        readings.devices = root.fixture
        root.testConfig = Config.defaultConfig()
        card.editMode = false
        slot = findChild(card, "gpuGauge")
        verify(slot !== null)
        slot.animationsEnabled = true
        tryCompare(slot, "transitioning", false, 1500)
      }
      function test_wheel_and_shared_temperature() {
        var width = card.width, height = card.height
        compare(slot.device.id, root.fixture[0].id)
        compare(findChild(slot, "gpuDeviceName").text, "Integrated GPU")
        compare(findChild(slot, "gpuDeviceDetail").text, root.fixture[0].name)
        compare(temperature.getTemp("GPU"), 42)
        mouseWheel(slot, 50, 50, 0, -120)
        compare(slot.device.id, root.fixture[1].id)
        compare(root.testConfig.widgets.systemMonitor.gpuDevice, root.fixture[1].id)
        compare(temperature.getTemp("GPU"), 53)
        compare(card.width, width)
        compare(card.height, height)
        tryCompare(slot, "transitioning", false, 1000)
        compare(findChild(slot, "gpuDeviceName").text, "Discrete GPU")
        compare(findChild(slot, "gpuDeviceDetail").text, root.fixture[1].name)
        mouseWheel(slot, 50, 50, 0, -120)
        compare(slot.device.id, root.fixture[0].id)
      }
      function test_swipe() {
        mouseDrag(slot, 85, 45, -60, 0)
        compare(slot.device.id, root.fixture[1].id)
      }
      function test_keyboard_and_arrow() {
        slot.forceActiveFocus()
        keyClick(Qt.Key_Right)
        compare(slot.device.id, root.fixture[1].id)
        tryCompare(slot, "transitioning", false, 1000)
        mouseClick(findChild(slot, "previousGpu"), 12, 12)
        compare(slot.device.id, root.fixture[0].id)
      }
      function test_edit_and_click_through() {
        card.editMode = true
        mouseWheel(slot, 50, 50, 0, -120)
        compare(slot.device.id, root.fixture[0].id)
        mouseDrag(slot, 85, 45, -60, 0)
        compare(slot.device.id, root.fixture[0].id)
        card.editMode = false
        var cfg = Config.deepMerge({}, root.testConfig)
        cfg.widgets.systemMonitor.clickThrough = true
        root.testConfig = cfg
        compare(slot.canSwitch, false)
        mouseWheel(slot, 50, 50, 0, -120)
        compare(slot.device.id, root.fixture[0].id)
      }
      function test_alias_unavailable_single_and_empty() {
        var cfg = Config.deepMerge({}, root.testConfig)
        cfg.widgets.systemMonitor.gpuAliases = { "0000:00:02.0": "Compute GPU" }
        root.testConfig = cfg
        compare(findChild(slot, "gpuDeviceName").text, "Compute GPU")
        compare(findChild(slot, "gpuDeviceDetail").text, root.fixture[0].name)
        cfg.widgets.systemMonitor.gpuAliases = { "0000:00:02.0": "" }
        root.testConfig = Config.deepMerge({}, cfg)
        compare(findChild(slot, "gpuDeviceName").text, "Integrated GPU")
        var height = card.height
        readings.devices = [{ id: root.fixture[0].id, name: "Intel UHD", kind: "Integrated GPU", utilization: null, temp: null, status: "Unavailable" }]
        compare(slot.canSwitch, false)
        compare(card.height, height)
        compare(temperature.gpuAvailable, false)
        readings.devices = []
        compare(findChild(slot, "gpuDeviceName").text, "No GPU detected")
        compare(card.height, height)
      }
      function test_touchpad_accumulation() {
        slot.scrollGpu(0, -15)
        slot.scrollGpu(0, -15)
        compare(slot.device.id, root.fixture[0].id)
        slot.scrollGpu(0, -15)
        compare(slot.device.id, root.fixture[1].id)
      }
      function test_transition_and_fast_scroll() {
        var width = card.width, height = card.height
        var outgoing = slot.currentPage
        mouseWheel(slot, 50, 50, 0, -120)
        compare(slot.transitioning, true)
        compare(slot.currentPage.device.id, root.fixture[1].id)
        compare(outgoing.device.id, root.fixture[0].id)
        compare(findChild(slot.currentPage, "gpuRing").value, 35)
        for (var i = 0; i < 5; i++) slot.scrollGpu(-120, 0)
        compare(slot.device.id, root.fixture[1].id)
        compare(slot.queuedDirection, 1)
        wait(80)
        verify(slot.currentPage.x > 0 && slot.currentPage.x < slot.width)
        verify(slot.currentPage.opacity > 0 && slot.currentPage.opacity < 1)
        // Live samples may update the incoming page, but the outgoing page
        // must retain the old GPU reading throughout the transition.
        readings.devices = root.fixture.map(function(device) {
          var copy = Object.assign({}, device)
          copy.utilization = device.vendor === "intel" ? 99 : 45
          return copy
        })
        compare(outgoing.device.utilization, 12)
        compare(slot.currentPage.device.utilization, 45)
        compare(findChild(slot.currentPage, "gpuRing").value, 45)
        tryCompare(slot, "transitioning", false, 1500)
        compare(slot.device.id, root.fixture[0].id)
        compare(slot.currentPage.device.id, root.fixture[0].id)
        compare(slot.currentPage.x, 0)
        compare(slot.currentPage.opacity, 1)
        compare(slot.otherPage.visible, false)
        compare(card.width, width)
        compare(card.height, height)
        // Updating a sample for the same GPU must not start a carousel slide.
        readings.devices = root.fixture
        compare(slot.transitioning, false)
      }
      function test_motion_disabled() {
        slot.animationsEnabled = false
        mouseWheel(slot, 50, 50, 0, -120)
        compare(slot.transitioning, false)
        compare(slot.currentPage.device.id, root.fixture[1].id)
        compare(slot.currentPage.x, 0)
        compare(slot.currentPage.opacity, 1)
      }
    }
  }
}
