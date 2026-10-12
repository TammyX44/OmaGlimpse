import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "." as Plugin
import "WidgetConfig.js" as Config
import "LayoutProfiles.js" as Profiles

// The runner stages the actual plugin and supplies a fresh /tmp directory.
// No persistence implementation is copied or mocked here.
ShellRoot {
  id: harness
  property bool ready: false
  property string fixtureDir: Quickshell.env("PERSISTENCE_TEST_DIR")
  Timer { interval: 100; running: true; onTriggered: harness.ready = true }
  Component {
    id: desktopComponent
    Plugin.Widgets {
      visible: false
      implicitWidth: 1536
      implicitHeight: 864
    }
  }
  Component {
    id: writerComponent
    FileView {
      atomicWrites: true
      blockWrites: true
      printErrors: false
      property int saves: 0
      property int errors: 0
      onSaved: saves++
      onSaveFailed: errors++
    }
  }
  Process {
    id: diskReader
    property string output: ""
    property int exitCode: -1
    stdout: StdioCollector { onStreamFinished: diskReader.output = text }
    onExited: function(code) { diskReader.exitCode = code }
  }
  TestCase {
    name: "NativePersistence"
    when: harness.ready
    property var desktop: null
    property string path: ""
    property int passes: 0
    property int failures: 0

    function diagnostic(label) {
      if (!desktop) { console.log("PERSISTENCE_STATE " + label + " destroyed"); return }
      console.log("PERSISTENCE_STATE " + label + " " + JSON.stringify({
        configLoaded: desktop.configLoaded,
        pendingConfig: desktop.pendingConfig !== null,
        inFlightText: desktop.inFlightText.length,
        lastSavedText: desktop.lastSavedText.length,
        persistenceBlocked: desktop.persistenceBlocked,
        externalConflict: desktop.externalConflict,
        activeLayoutKey: desktop.activeLayoutKey,
        currentKey: desktop.currentLayoutKey,
        layoutSwitchPending: desktop.layoutSwitchPending,
        saveStatus: desktop.saveStatus,
        configError: desktop.configError,
        width: desktop.width, height: desktop.height
      }))
    }
    function command(args) {
      diskReader.output = ""
      diskReader.exitCode = -1
      diskReader.command = args
      diskReader.running = true
      tryCompare(diskReader, "running", false, 3000)
      compare(diskReader.exitCode, 0, "Independent disk command failed: " + args.join(" "))
      return diskReader.output
    }
    function diskText() { return command(["cat", "--", path]) }
    function seed(extraWhitespace) {
      verify(/^\/tmp\/omaglimpse-persistence-tests\.[^/]+\/fixtures$/.test(harness.fixtureDir),
             "Refuse any persistence target outside the runner's isolated fixture")
      path = harness.fixtureDir + "/" + qtest_results.functionName + ".json"
      var cfg = Config.parseConfig(JSON.stringify(Config.defaultConfig()))
      Config.allWidgetIds().forEach(function(id) { cfg.widgets[id].enabled = false })
      cfg.widgets.networkSpeed.enabled = true
      cfg.widgets.networkSpeed.x = 180
      cfg.widgets.networkSpeed.y = 140
      cfg.widgets.networkSpeed.cardWidth = 280
      cfg.widgets.networkSpeed.cardHeight = 170
      cfg.widgets.networkSpeed.showHistory = false
      cfg.widgets.battery.cardHeight = 170
      cfg.global.blurEnabled = false
      var screens = []
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var s = Quickshell.screens[i]
        if (s.width > 0 && s.height > 0) screens.push({name:s.name, width:s.width,
          height:s.height, scale:s.devicePixelRatio, x:s.x, y:s.y})
      }
      verify(screens.length > 0, "These native PanelWindow cases require Wayland screens")
      var key = Profiles.profileKey(screens, screens[0].name)
      cfg.activeMonitorLayout = key
      cfg = Profiles.remember(cfg, key)
      // The teardown case uses harmless whitespace so the old startup save
      // really writes; its failure then isolates lost debounced edits.
      var encoded = JSON.stringify(cfg, null, 2) + "\n" + (extraWhitespace ? "\n" : "")
      var writer = writerComponent.createObject(harness, {path:path})
      verify(writer !== null)
      writer.setText(encoded)
      compare(writer.errors, 0)
      compare(writer.saves, 1, "Seed must use a real atomic FileView write")
      writer.destroy()
      compare(diskText(), encoded)
      return encoded
    }
    function createDesktop() {
      desktop = desktopComponent.createObject(harness, {configPath:path})
      verify(desktop !== null)
      compare(desktop.configPath, path)
      tryCompare(desktop, "configLoaded", true, 3000)
      diagnostic("loaded")
      tryVerify(function() { return !desktop.layoutSwitchPending }, 3000)
    }
    function idle(label) {
      var settled = false
      for (var i = 0; i < 60; i++) {
        if (!desktop.pendingConfig && !desktop.inFlightText && !desktop.layoutSwitchPending) {
          settled = true; break
        }
        wait(50)
      }
      diagnostic(label)
      verify(settled, "Persistence did not settle; see PERSISTENCE_STATE " + label)
      compare(desktop.persistenceBlocked, false)
      compare(desktop.externalConflict, false)
    }
    function destroyDesktop() {
      diagnostic("before-destroy")
      desktop.destroy()
      desktop = null
      // QObject.destroy() is deferred; this also executes Component.onDestruction.
      wait(100)
      diagnostic("after-destroy")
    }
    function checkSettings(cfg, x, y, height) {
      compare(cfg.widgets.networkSpeed.enabled, true)
      compare(cfg.widgets.networkSpeed.x, x)
      compare(cfg.widgets.networkSpeed.y, y)
      compare(cfg.widgets.networkSpeed.cardWidth, 280)
      compare(cfg.widgets.networkSpeed.cardHeight, height)
      compare(cfg.widgets.battery.enabled, false)
      compare(cfg.widgets.battery.cardHeight, 170)
    }
    function cleanup() {
      if (qtest_results.failed) {
        failures++
        diagnostic("FAILED-" + qtest_results.functionName)
        console.error("PERSISTENCE_UI_FAILED " + qtest_results.functionName)
      } else {
        passes++
        console.log("PERSISTENCE_UI_PASSED " + qtest_results.functionName)
      }
      if (desktop) destroyDesktop()
    }
    function cleanupTestCase() {
      console.log("PERSISTENCE_UI_TOTAL " + passes + " passed, " + failures + " failed")
    }
    function test_a_unchanged_startup_then_edit_and_recreate() {
      var original = seed()
      createDesktop()
      // Startup monitor switching saves the same bytes already on disk.
      idle("startup-unchanged-save")
      compare(diskText(), original, "Startup must not change saved settings")
      checkSettings(desktop.config, 180, 140, 170)
      desktop.saveConfig()
      wait(650)
      idle("explicit-unchanged-save-before-edits")
      var before = command(["stat", "--printf=%i|%y", "--", path])
      desktop.updateWidgetPosition("networkSpeed", 264, 208)
      desktop.updateWidgetConfig("networkSpeed", "cardHeight", 238)
      diagnostic("after-edits")
      idle("durable-edits")
      var saved = diskText()
      checkSettings(JSON.parse(saved), 264, 208, 238)
      compare(saved, desktop.lastSavedText)
      verify(command(["stat", "--printf=%i|%y", "--", path]) !== before,
             "Successful edit must replace/update the disk file")
      destroyDesktop()
      compare(diskText(), saved)
      createDesktop()
      idle("recreated")
      checkSettings(desktop.config, 264, 208, 238)
      compare(JSON.stringify(desktop.config), JSON.stringify(JSON.parse(saved)))
      compare(diskText(), saved)
    }
    function test_b_destroy_before_debounce_and_recreate() {
      seed(true)
      createDesktop()
      idle("before-debounce-edits")
      desktop.updateWidgetPosition("networkSpeed", 312, 224)
      desktop.updateWidgetConfig("networkSpeed", "cardHeight", 246)
      verify(desktop.pendingConfig !== null)
      compare(desktop.inFlightText, "")
      // No event-loop wait between edits and destroy: comfortably within 500ms.
      destroyDesktop()
      var saved = diskText()
      checkSettings(JSON.parse(saved), 312, 224, 246)
      createDesktop()
      idle("recreated-after-debounce-destruction")
      checkSettings(desktop.config, 312, 224, 246)
      compare(JSON.stringify(desktop.config), JSON.stringify(JSON.parse(saved)))
      compare(diskText(), saved)
    }
  }
}
