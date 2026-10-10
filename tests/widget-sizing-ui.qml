import QtQuick
import QtTest
import Quickshell
import "." as Plugin
import "WidgetConfig.js" as Config

ShellRoot {
  id: root
  property bool ready: false
  Timer { interval: 300; running: true; onTriggered: root.ready = true }
  FloatingWindow {
    visible: true
    implicitWidth: 1100; implicitHeight: 850
    color: "#151821"
    Item {
      id: preview
      width: 1100; height: 900
      Rectangle { anchors.fill: parent; color: "#151821" }
      Plugin.SystemMonitor { id: system; x: 24; y: 24; samplingEnabled: false }
      Plugin.BatteryWidget { id: battery; x: 548; y: 24; samplingEnabled: false }
      Plugin.Temperature { id: temperature; x: 832; y: 24; samplingEnabled: false }
      Plugin.MediaWidget { id: media; x: 24; y: 308; samplingEnabled: false }
      Plugin.TopProcesses { id: processes; x: 378; y: 308; samplingEnabled: false }
      Plugin.DiskUsage { id: disk; x: 732; y: 308; samplingEnabled: false }
      Plugin.NetworkSpeed { id: network; x: 24; y: 582; samplingEnabled: false }
      Plugin.WidgetSizeControls {
        id: controls
        x: 378; y: 606; width: 460
        widgetId: "demo"
        widgetCfg: ({cardWidth:330,cardHeight:280})
        minimumHeight: 210
        actualHeight: 280
      }
    }
    TestCase {
      name: "WidgetSizing"
      when: root.ready
      property var cards: [system,battery,media,processes,network,disk,temperature]
      property int passes: 0
      property int failures: 0
      SignalSpy { id: dimensions; target: controls; signalName: "dimensionChanged" }
      function cleanup() {
        if (qtest_results.failed) { failures++; console.error("SIZING_UI_FAILED " + qtest_results.functionName) }
        else passes++
      }
      function cleanupTestCase() { console.log("SIZING_UI_TOTAL " + passes + " passed, " + failures + " failed") }
      function configure(card, width, height) {
        var cfg = Config.defaultConfig()
        cfg.widgets[card.widgetId].cardWidth = width
        cfg.widgets[card.widgetId].cardHeight = height
        card.config = cfg
      }
      function assertContentFits(card) {
        var content = findChild(card, "widgetSizingContent")
        verify(content !== null)
        var point = card.mapFromItem(content, 0, 0)
        verify(point.y >= -1, card.widgetId + ": top")
        verify(point.y + content.height <= card.height + 1, card.widgetId + ": bottom")
        verify(point.x >= -1, card.widgetId + ": left")
        verify(point.x + content.width <= card.width + 1, card.widgetId + ": right")
        if (card.widgetId !== "media")
          verify(Math.abs(point.y - (card.height - content.height) / 2) <= 1, card.widgetId + ": centred")
      }
      function test_a_every_card_auto_manual_and_content_floor() {
        for (var i = 0; i < cards.length; i++) {
          var card = cards[i]
          for (var w of [200, 330, 500]) {
            configure(card, w, 0)
            wait(30)
            compare(card.width, w)
            compare(card.height, card.naturalCardHeight)
            var natural = card.naturalCardHeight
            configure(card, w, 80)
            wait(30)
            compare(card.height, Math.max(80, card.minimumCardHeight))
            assertContentFits(card)
            configure(card, w, Math.ceil(natural + 100))
            wait(30)
            compare(card.height, Math.max(Math.ceil(natural + 100), card.minimumCardHeight))
            assertContentFits(card)
            configure(card, w, 0)
            wait(30)
            compare(card.height, card.naturalCardHeight)
          }
        }
      }
      function test_b_dynamic_content_and_empty_system_card() {
        configure(processes, 330, 80)
        processes.processes = Array.from({length:15}, function(_, i) { return {name:"demo " + i,cpu:i,mem:1} })
        wait(50)
        compare(processes.height, Math.max(80, processes.minimumCardHeight))
        var processViewport = findChild(processes, "listCardViewport")
        verify(processViewport !== null)
        verify(processViewport.contentHeight > processViewport.height)
        processViewport.contentY = processViewport.contentHeight - processViewport.height
        verify(processViewport.contentY > 0)
        assertContentFits(processes)
        configure(disk, 330, 80)
        disk.disks = [{mount:"/",used:"18G",size:"128G",avail:"110G",percent:14},
          {mount:"/demo",used:"12G",size:"64G",avail:"52G",percent:19}]
        disk.hasLoaded = true
        disk.errorMessage = "An example error with enough words to wrap safely across the card."
        wait(50)
        assertContentFits(disk)
        configure(system, 200, 80)
        system.config = {widgets:{systemMonitor:{cardWidth:200,cardHeight:80,showCpu:false,showRam:false,showGpu:false}}}
        wait(50)
        compare(system.height, 80)
      }
      function test_d_compact_matrix_keeps_dimensions_and_geometry() {
        for (var card of cards) {
          for (var width of [200, 330, 500]) {
            for (var height of [80,100,120,160,220,400]) {
              configure(card, width, height)
              wait(50)
              compare(card.width, width)
              compare(card.height, Math.max(height, card.minimumCardHeight))
              assertContentFits(card)
              compare(card.scale, 1)
            }
          }
        }
        compare(findChild(network, "networkHistoryGraph").scale, 1)
        configure(network, 200, 90)
        for (var state of ["Paused", "Unavailable", "Measuring…"]) {
          network.sampleReady = false
          network.sampleState = state
          wait(50)
          verify(findChild(network, "networkInterfaceHeader").text.indexOf(state) !== -1)
          assertContentFits(network)
        }
        battery.profiles = ["power-saver", "balanced", "performance"]
        battery.profileError = "Example error with a very long message retained for accessibility"
        for (var width of [200,330,500]) {
          for (var height of [80,100,199,200,220]) {
            configure(battery, width, height)
            wait(50)
            compare(battery.height, height)
            assertContentFits(battery)
          }
        }
        battery.profileError = ""
        configure(temperature, 200, 80)
        temperature.config.widgets.temperature.unit = "fahrenheit"
        temperature.configChanged()
        temperature.cpuAvailable = true
        temperature.gpuAvailable = true
        temperature.temps = [{name:"CPU",temp:99},{name:"GPU",temp:85}]
        temperature.animatedHottestTemp = 99
        temperature.hottestTemp = 99
        temperature.hottestSensor = "CPU"
        temperature.fanRpm = 12345
        wait(50)
        assertContentFits(temperature)
      }
      function test_c_size_rows_reset_and_keyboard() {
        for (var width of [300,460]) {
          controls.width = width
          wait(30)
          for (var id of ["demoHeightSlider","demoWidthSlider","demoHeightValue","demoWidthValue","demoHeightAuto","demoWidthAuto"]) {
            var child = findChild(controls, id)
            verify(child !== null)
            var point = controls.mapFromItem(child, 0, 0)
            verify(point.x >= 0 && point.x + child.width <= controls.width + 1, id)
          }
        }
        controls.width = 460
        var slider = findChild(controls, "demoHeightSlider")
        compare(slider.minimum, 210)
        dimensions.clear()
        slider.moved(320)
        compare(dimensions.signalArguments[0][0], "cardHeight")
        compare(dimensions.signalArguments[0][1], 320)
        dimensions.clear()
        findChild(controls, "demoHeightAuto").clicked()
        compare(dimensions.signalArguments[0][1], 0)
        dimensions.clear()
        slider.forceActiveFocus()
        compare(findChild(controls, "demoHeightFocus").visible, true)
        keyClick(Qt.Key_Right)
        compare(dimensions.signalArguments[0][1], 290)
        controls.minimumHeight = 1400
        controls.actualHeight = 1400
        controls.widgetCfg = {cardWidth:330,cardHeight:0}
        compare(slider.value, 1000)
        dimensions.clear()
        keyClick(Qt.Key_Left)
        compare(dimensions.signalArguments[0][1], 1000)
        dimensions.clear()
        slider.moved(1390)
        compare(dimensions.signalArguments[0][1], 1000)
        controls.minimumHeight = 210
        controls.actualHeight = 280
        controls.widgetCfg = {cardWidth:330,cardHeight:280}
        var reset = findChild(controls, "demoHeightAuto")
        reset.forceActiveFocus()
        compare(reset.border.width, 1)
        dimensions.clear()
        keyClick(Qt.Key_Return)
        compare(dimensions.signalArguments[0][1], 0)
      }
      function test_z_capture_safe_fixture() {
        if (!Quickshell.env("SIZING_TEST_IMAGE") && !Quickshell.env("SIZING_GEOMETRY_ONLY")) return
        var compact = !!Quickshell.env("SIZING_COMPACT_IMAGE")
        configure(system, 500, compact ? 110 : 0)
        configure(battery, 260, compact ? 80 : 0)
        configure(temperature, 240, compact ? 80 : 0)
        configure(media, 330, compact ? 100 : 0)
        configure(processes, 330, compact ? 100 : 0)
        configure(disk, 330, compact ? 80 : 0)
        configure(network, 330, compact ? 90 : 0)
        system.cpuReady = true; system.cpuValue = 18; system.cpuUser = 12
        system.memReady = true; system.memValue = 46; system.ramUsedGb = 7.2; system.ramFreeGb = 8.4
        system.gpuMonitor = {discoveryReady:true,devices:[
          {id:"fixture-integrated",kind:"iGPU",name:"Fixture integrated GPU",utilization:24,temp:43,status:"Ready"},
          {id:"fixture-discrete",kind:"dGPU",name:"Fixture discrete GPU",utilization:12,temp:46,status:"Ready"}]}
        if (compact) findChild(system, "gpuGauge").forceActiveFocus()
        battery.profiles = ["power-saver","balanced","performance"]; battery.activeProfile = "balanced"
        processes.processes = [{name:"demo-player",cpu:12.8,mem:1.2},{name:"demo-editor",cpu:4.2,mem:2.1}]
        processes.hasLoaded = true
        disk.errorMessage = ""; disk.hasLoaded = true
        disk.disks = [{mount:"/",used:"18G",size:"128G",avail:"110G",percent:14}]
        temperature.cpuAvailable = true; temperature.gpuAvailable = true
        temperature.temps = [{name:"CPU",temp:52},{name:"GPU",temp:43}]
        temperature.hottestTemp = 52; temperature.animatedHottestTemp = 52; temperature.hottestSensor = "CPU"; temperature.fanRpm = 2800
        network.sampleReady = true; network.activeInterface = "demo0"
        network.rxSpeed = 1250000; network.txSpeed = 180000; network.autoScale = 2000000
        wait(400)
        for (var card of cards) {
          assertContentFits(card)
          verify(card.x + card.width <= preview.width)
          verify(card.y + card.height <= preview.height)
          var content = findChild(card, "widgetSizingContent")
          var point = card.mapFromItem(content, 0, 0)
          console.log("SIZING_GEOMETRY " + card.widgetId + " height=" + card.height
            + " contentY=" + point.y + " contentHeight=" + content.height)
        }
        if (!Quickshell.env("SIZING_TEST_IMAGE")) return
        var saved = false
        preview.grabToImage(function(result) { saved = result.saveToFile(Quickshell.env("SIZING_TEST_IMAGE")) })
        tryVerify(function() { return saved }, 2000)
      }
    }
  }
}
