import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import "." as Plugin
import "WidgetConfig.js" as Config
import "LayoutProfiles.js" as Profiles

ShellRoot {
  id: root
  property bool ready: false
  property var fixture: Config.parseConfig('{"widgets":{"systemMonitor":{"enabled":false},"battery":{"enabled":false},"media":{"enabled":false},"topProcesses":{"enabled":false}}}')
  Timer { interval: 800; running: true; onTriggered: root.ready = true }
  Plugin.Widgets {
    id: desktop
    visible: false
    configPath: Quickshell.env("LAYOUT_TEST_CONFIG")
  }
  Plugin.SettingsPanel {
    id: settings
    config: root.fixture
    expandedWidgets: ({networkSpeed:true})
    displayInventory: [{name:"Laptop",width:1920,height:1080,scale:1}]
    selectedDisplay: "Laptop"
  }
  FloatingWindow {
    visible: true
    implicitWidth: 820; implicitHeight: 780
    color: "#151821"
    Item {
      id: preview
      width: 820; height: 700
      Rectangle { anchors.fill: parent; color: "#151821" }
    Plugin.LayoutEditorControls {
      id: editor
      x: 24; y: 24; width: 440
      config: ({editor:{snapToGrid:true,snapToCards:true,gridSize:8},namedLayouts:{Work:{}}})
      displayInventory: [{name:"Laptop",width:1920,height:1080,scale:1}]
      selectedDisplay: "Laptop"
      undoAvailable: true
      hostActive: true
    }
    Plugin.NetworkSpeed {
      id: network
      x: 500; y: 24
      samplingEnabled: false
      config: ({widgets:{networkSpeed:{cardWidth:280,showHistory:true,scaleMode:"auto"}}})
      sampleReady: true
      rxSpeed: 1250000; txSpeed: 180000
      autoScale: 2000000
      historyTime: 60000
      history: [{time:30000,rx:100000,tx:50000},{time:40000,rx:800000,tx:100000},
        {time:50000,rx:1800000,tx:230000},{time:60000,rx:1250000,tx:180000}]
    }
    }
    TestCase {
      name: "LayoutEditor"
      when: root.ready
      property int passes: 0
      property int failures: 0
      SignalSpy { id: layoutSpy; target: editor; signalName: "namedLayoutRequested" }
      function cleanup() {
        if (qtest_results.failed) { failures++; console.error("LAYOUT_UI_FAILED " + qtest_results.functionName) }
        else passes++
      }
      function cleanupTestCase() { console.log("LAYOUT_UI_TOTAL " + passes + " passed, " + failures + " failed") }
      function test_a_root_loads_isolated_settings() {
        compare(desktop.configLoaded, true)
        compare(desktop.allEnabledIds.length, 0)
        compare(desktop.configPath, Quickshell.env("LAYOUT_TEST_CONFIG"))
        compare(desktop.WlrLayershell.keyboardFocus, WlrKeyboardFocus.OnDemand)
      }
      function test_b_undo_restores_layout_preserves_preferences() {
        desktop.undoStack = []
        desktop.updateWidgetConfig("battery", "x", 240)
        desktop.updateWidgetConfig("battery", "y", 120)
        compare(desktop.undoStack.length, 1)
        desktop.updateWidgetConfig("battery", "showPower", false)
        desktop.undoLayout()
        compare(desktop.config.widgets.battery.x, -1)
        compare(desktop.config.widgets.battery.y, -1)
        compare(desktop.config.widgets.battery.showPower, false)
      }
      function test_c_named_layout_round_trip_and_undo() {
        desktop.updateWidgetConfig("battery", "x", 320)
        desktop.namedLayout("Work", "save")
        desktop.updateWidgetConfig("battery", "x", 64)
        desktop.namedLayout("Work", "load")
        compare(desktop.config.widgets.battery.x, 320)
        desktop.undoLayout()
        compare(desktop.config.widgets.battery.x, 64)
        desktop.namedLayout("Work", "delete")
        verify(!Object.prototype.hasOwnProperty.call(desktop.config.namedLayouts, "Work"))
      }
      function test_f_height_undo_and_settings_control() {
        desktop.undoStack = []
        desktop.lastHistoryGroup = ""
        desktop.updateWidgetConfig("battery", "cardHeight", 360)
        compare(desktop.config.widgets.battery.cardHeight, 360)
        compare(desktop.undoStack.length, 1)
        desktop.undoLayout()
        compare(desktop.config.widgets.battery.cardHeight, 0)
        var heightSlider = findChild(settings.contentItem, "networkSpeedHeightSlider")
        var widthSlider = findChild(settings.contentItem, "networkSpeedWidthSlider")
        verify(heightSlider !== null)
        verify(widthSlider !== null)
        var auto = findChild(settings.contentItem, "networkSpeedHeightAuto")
        verify(auto !== null)
      }
      function test_d_native_settings_and_narrow_controls() {
        verify(findChild(settings.contentItem, "layoutDisplayPicker") !== null)
        for (var i = 0; i < 2; i++) {
          editor.width = i === 0 ? 440 : 300
          wait(50)
          for (var j = 0; j < editor.children.length; j++) {
            var child = editor.children[j]
            if (child.visible && child.width > 0)
              verify(child.x + child.width <= editor.width + 1)
          }
          var input = findChild(editor, "layoutNameInput")
          verify(input !== null)
          compare(input.maximumLength, 48)
        }
        editor.width = 440
        input.text = "W\u007fork"
        var saveButton = findChild(editor, "saveNamedLayoutButton")
        compare(saveButton.layoutName, "Work")
        compare(saveButton.exists, true)
        layoutSpy.clear()
        saveButton.clicked()
        compare(layoutSpy.count, 0)
        saveButton.clicked()
        compare(layoutSpy.count, 1)
        compare(layoutSpy.signalArguments[0][0], "Work")
        input.text = ""
      }
      function test_e_monitor_profiles_fit_without_mutating_previous_setup() {
        desktop.config.widgets.battery.x = 1600
        var oldKey = Profiles.profileKey([{name:"Laptop",width:1920,height:1080,scale:1}],"Laptop")
        var smallKey = Profiles.profileKey([{name:"Laptop",width:1280,height:720,scale:1.5}],"Laptop")
        var next = Profiles.switchProfile(desktop.config, oldKey, smallKey)
        next.widgets.battery.x = 980
        next = Profiles.remember(next, smallKey)
        compare(Profiles.switchProfile(next, smallKey, oldKey).widgets.battery.x, 1600)
      }
      function test_z_capture_safe_fixture() {
        if (!Quickshell.env("LAYOUT_TEST_IMAGE")) return
        network.sampleReady = true
        network.activeInterface = "demo0"
        network.rxSpeed = 1250000; network.txSpeed = 180000
        network.autoScale = 2000000
        network.historyTime = 60000
        network.history = [{time:30000,rx:100000,tx:50000},{time:40000,rx:800000,tx:100000},
          {time:50000,rx:1800000,tx:230000},{time:60000,rx:1250000,tx:180000}]
        verify(network.x + network.width <= preview.width)
        verify(network.y + network.height <= preview.height)
        wait(100)
        var saved = false
        preview.grabToImage(function(result) {
          saved = result.saveToFile(Quickshell.env("LAYOUT_TEST_IMAGE"))
        })
        tryVerify(function() { return saved }, 2000)
        settings.visible = true
        settings.scrollTargetWidget = "networkSpeed"
        settings.scrollToRequestedWidget()
        wait(300)
        var settingsView = findChild(settings.contentItem, "widgetSettingsCard")
        saved = false
        settingsView.grabToImage(function(result) {
          saved = result.saveToFile(Quickshell.env("LAYOUT_TEST_IMAGE") + ".settings.png")
        })
        tryVerify(function() { return saved }, 2000)
        var dropdown = findChild(settings.contentItem, "networkScaleDropdown")
        verify(dropdown !== null)
        dropdown.open()
        tryCompare(dropdown, "popupOpen", true)
        settings.visible = false
        tryCompare(dropdown, "popupOpen", false)
      }
    }
  }
}
