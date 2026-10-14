import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.UPower
import "." as Plugin

ShellRoot {
  id: root
  property bool startTests: false
  Timer { interval: 100; running: true; onTriggered: root.startTests = true }
  Plugin.SamplingPolicy { id: policy; monitoringEnabled: false }
  FloatingWindow {
    visible: true
    implicitWidth: 800; implicitHeight: 600
    Plugin.SystemMonitor {
      id: systemCard
      samplingEnabled: false
      config: ({ widgets: { systemMonitor: { showGpu: false, refreshInterval: 500 } } })
    }
    Plugin.Temperature {
      id: temperatureCard
      y: 150
      samplingEnabled: false
      config: ({ widgets: { temperature: { sensors: [], showFan: false } } })
    }
    Plugin.DiskUsage { id: diskCard; x: 400; samplingEnabled: false }
    Plugin.MediaWidget { id: mediaCard; x: 400; y: 250; samplingEnabled: false }
    Plugin.BatteryWidget {
      id: batteryCard
      y: 300
      samplingEnabled: false
      config: ({ widgets: { battery: { showProfiles: false } } })
    }
    TestCase {
      name: "Sampling"
      when: root.startTests
      property int passes: 0
      property int failures: 0
      function cleanup() {
        if (qtest_results.failed) failures++
        else passes++
      }
      function cleanupTestCase() {
        console.log("SAMPLING_UI_TOTAL " + passes + " passed, " + failures + " failed")
      }
      function test_policy_lock_dpms_resume_and_unknown() {
        compare(policy.powerSaver, PowerProfiles.profile === PowerProfile.PowerSaver)
        policy.observeLock("false")
        policy.observeDisplays('[{"name":"eDP-1","dpmsStatus":true}]')
        compare(policy.samplingEnabled, true)
        policy.observeLock("true")
        compare(policy.samplingEnabled, false)
        policy.observeLock("bad")
        compare(policy.locked, true)
        verify(policy.lockMonitorError !== "")
        policy.observeLock("false")
        compare(policy.samplingEnabled, true)
        policy.observeDisplays('[{"dpmsStatus":false}]')
        compare(policy.samplingEnabled, false)
        policy.observeDisplays("unavailable")
        compare(policy.displayOn, false)
        verify(policy.displayMonitorError !== "")
        policy.observeDisplays('[{"dpmsStatus":true}]')
        compare(policy.samplingEnabled, true)
        policy.enabled = false
        compare(policy.samplingEnabled, false)
        policy.enabled = true
      }
      function test_all_card_timers_pause_and_scale() {
        var cards = [systemCard, temperatureCard, diskCard, mediaCard, batteryCard]
        var timers = ["systemSamplingTimer", "temperatureSamplingTimer", "diskSamplingTimer",
          "mediaPositionTimer", "hardwareProfileTimer"]
        for (var i = 0; i < cards.length; i++) {
          cards[i].samplingEnabled = false
          var timer = findChild(cards[i], timers[i])
          verify(timer !== null)
          compare(timer.running, false)
          var normal = timer.interval
          cards[i].samplingMultiplier = 3
          compare(timer.interval, normal * 3)
          cards[i].samplingMultiplier = 1
        }
        compare(findChild(mediaCard, "mediaPositionSyncTimer").running, false)
        compare(findChild(temperatureCard, "temperatureRetryTimer").running, false)
      }
      function test_cpu_resume_discards_old_delta() {
        systemCard.samplingEnabled = true
        wait(50)
        systemCard.prevCpuStat = null
        systemCard.updateCpuStat('cpu 100 0 50 800 50 0 0 0')
        compare(systemCard.cpuReady, false)
        systemCard.updateCpuStat('cpu 120 0 60 860 60 0 0 0')
        compare(systemCard.cpuReady, true)
        compare(systemCard.cpuValue, 30)
        systemCard.samplingEnabled = false
        compare(systemCard.prevCpuStat, null)
        compare(systemCard.cpuReady, false)
        systemCard.updateCpuStat('cpu 200 0 60 860 60 0 0 0')
        compare(systemCard.prevCpuStat, null)
        systemCard.samplingEnabled = true
        tryVerify(function() { return systemCard.prevCpuStat !== null }, 1000)
        systemCard.samplingEnabled = false
      }
      function test_disk_resume_samples_immediately() {
        compare(diskCard.hasLoaded, false)
        diskCard.refresh()
        compare(findChild(diskCard, "diskSamplingProcess").running, false)
        diskCard.samplingEnabled = true
        tryCompare(diskCard, "hasLoaded", true, 2000)
        compare(diskCard.errorMessage, "")
        diskCard.samplingEnabled = false
      }
      function test_temperature_ignores_paused_readings_and_resumes() {
        temperatureCard.updateCpuTemp("50000")
        compare(temperatureCard.cpuAvailable, false)
        temperatureCard.samplingEnabled = true
        temperatureCard.updateCpuTemp("50000")
        compare(temperatureCard.cpuAvailable, true)
        temperatureCard.samplingEnabled = false
        temperatureCard.updateCpuTemp("90000")
        compare(temperatureCard.getTemp("CPU"), 50)
      }
      function test_native_profile_notification_is_wired_without_writing_profile() {
        batteryCard.activeProfile = "stale"
        PowerProfiles.profileChanged()
        compare(batteryCard.activeProfile, batteryCard.nativeProfileName())
        compare(findChild(batteryCard, "hardwareProfileProcess").running, false)
      }
      function test_battery_requires_fresh_hardware_confirmation() {
        batteryCard.profiles = ["power-saver", "balanced", "performance"]
        batteryCard.pendingProfile = "power-saver"
        batteryCard.confirmationReadSerial = 5
        var timer = findChild(batteryCard, "profileConfirmationTimer")
        timer.start()
        batteryCard.updateActiveProfile("low-power", 4)
        compare(batteryCard.pendingProfile, "power-saver")
        batteryCard.updateActiveProfile("low-power", 5)
        compare(batteryCard.pendingProfile, "")
        compare(timer.running, false)
        batteryCard.setProfile("unsupported")
        compare(batteryCard.profileError, "Unsupported power profile")
      }
      function test_z_sensor_errors_and_cancelled_disk() {
        temperatureCard.samplingEnabled = true
        temperatureCard.updateFan("")
        compare(temperatureCard.fanRpm, -1)
        temperatureCard.updateFan("0")
        compare(temperatureCard.fanRpm, 0)
        temperatureCard.updateCpuTemp("0")
        compare(temperatureCard.cpuAvailable, true)
        compare(temperatureCard.getTemp("CPU"), 0)
        temperatureCard.updateCpuTemp("invalid")
        compare(temperatureCard.cpuAvailable, false)
        temperatureCard.samplingEnabled = false
        diskCard.samplingEnabled = false
        diskCard.hasLoaded = false
        diskCard.errorMessage = ""
        diskCard.collectionActive = true
        diskCard.pendingSampleEpoch = diskCard.sampleEpoch - 1
        diskCard.pendingExitCode = 1
        diskCard.pendingStderr = "cancelled old read"
        diskCard.stdoutReady = diskCard.stderrReady = diskCard.exitReady = true
        diskCard.finishRefresh()
        compare(diskCard.hasLoaded, false)
        compare(diskCard.errorMessage, "")
        compare(diskCard.collectionActive, false)
      }
      function test_battery_confirmation_timeout_retains_error() {
        batteryCard.pendingProfile = "performance"
        var timer = findChild(batteryCard, "profileConfirmationTimer")
        timer.interval = 30
        timer.restart()
        tryCompare(batteryCard, "pendingProfile", "", 500)
        compare(batteryCard.profileError, "Profile change not confirmed by hardware")
        timer.interval = 3000
      }
    }
  }
}
