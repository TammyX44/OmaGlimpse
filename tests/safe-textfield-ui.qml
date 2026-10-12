import QtQuick
import QtTest
import Quickshell
import "." as Plugin

ShellRoot {
  id: harness
  property bool ready: false
  Timer { interval: 150; running: true; onTriggered: harness.ready = true }
  FloatingWindow {
    visible: true
    implicitWidth: 520
    implicitHeight: 230
    Item {
      id: preview
      anchors.fill: parent
      Rectangle { anchors.fill: parent; color: "#151821" }
      Plugin.SafeTextField {
        id: field
        x: 24; y: 24; width: 300; height: 36
        maximumLength: 48
        placeholderText: "e.g. Work or Gaming"
        Accessible.name: "New layout name"
      }
      Plugin.SafeTextField {
        id: coordinate
        x: 24; y: 90; width: 78; height: 28
        maximumLength: 5
        allowedPattern: /^[0-9]*$/
        text: "120"
        placeholderText: "Auto"
        font.pixelSize: 11
        horizontalAlignment: Text.AlignHCenter
        Accessible.name: "Widget X position"
      }
      Plugin.SafeTextField {
        id: colorField
        x: 24; y: 144; width: 160; height: 36
        maximumLength: 9
        text: "#7aa2f7"
        placeholderText: "#RRGGBB"
        Accessible.name: "Accent color"
      }
    }
    TestCase {
      name: "SafeTextFieldRuntime"
      when: harness.ready
      property int passes: 0
      property int failures: 0
      SignalSpy { id: commitSpy; target: field; signalName: "editingFinished" }
      function cleanup() {
        if (qtest_results.failed) { failures++; console.error("SAFE_FIELD_FAILED " + qtest_results.functionName) }
        else passes++
      }
      function cleanupTestCase() { console.log("SAFE_FIELD_TOTAL " + passes + " passed, " + failures + " failed") }
      function renderer(control) {
        var item = findChild(control, "safeTextRenderer")
        verify(item !== null)
        compare(item.readOnly, true)
        compare(item.canPaste, false)
        return item
      }
      function test_a_keyboard_editing_keeps_renderer_readonly() {
        field.text = ""
        field.forceActiveFocus()
        keyClick(Qt.Key_A)
        keyClick(Qt.Key_B)
        keyClick(Qt.Key_C)
        compare(field.text, "abc")
        renderer(field)
        keyClick(Qt.Key_Left)
        keyClick(Qt.Key_Backspace)
        compare(field.text, "ac")
        keyClick(Qt.Key_Delete)
        compare(field.text, "a")
        keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_D)
        compare(field.text, "d")
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(field.text, "a")
        keyClick(Qt.Key_Y, Qt.ControlModifier)
        compare(field.text, "d")
        keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_X, Qt.ControlModifier)
        compare(field.text, "")
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(field.text, "d")
        renderer(field)
        commitSpy.clear()
        keyClick(Qt.Key_Return)
        verify(commitSpy.count > 0)
      }
      function test_b_limits_and_numeric_pattern() {
        coordinate.forceActiveFocus()
        keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_1)
        keyClick(Qt.Key_2)
        keyClick(Qt.Key_3)
        keyClick(Qt.Key_4)
        keyClick(Qt.Key_5)
        keyClick(Qt.Key_6)
        compare(coordinate.text, "12345")
        keyClick(Qt.Key_Z)
        compare(coordinate.text, "12345")
        renderer(coordinate)
        coordinate.text = "120"
      }
      function test_c_explicit_paste_only_from_bounded_helper() {
        field.text = ""
        field.forceActiveFocus()
        keyClick(Qt.Key_V, Qt.ControlModifier)
        tryCompare(field, "text", "Safe paste", 3500)
        renderer(field)
        coordinate.forceActiveFocus()
        keyClick(Qt.Key_A, Qt.ControlModifier)
        keyClick(Qt.Key_V, Qt.ControlModifier)
        tryVerify(function() { return coordinate.pasteError !== "" }, 3500)
        compare(coordinate.text, "120")
        verify(coordinate.pasteError !== "")
        renderer(coordinate)
      }
      function test_d_focus_loss_cancels_late_paste() {
        field.text = "kept"
        field.forceActiveFocus()
        keyClick(Qt.Key_V, Qt.ControlModifier)
        coordinate.forceActiveFocus()
        wait(600)
        compare(field.text, "kept")
        renderer(field)
      }
      function test_e_unicode_selection_and_length_are_bounded() {
        field.text = ""
        field.maximumLength = 4
        field.forceActiveFocus()
        field.insertText("😀ABCD")
        compare(field.text, "😀AB")
        keyClick(Qt.Key_Home)
        keyClick(Qt.Key_Delete)
        compare(field.text, "AB")
        field.maximumLength = 1
        field.text = ""
        field.insertText("😀")
        compare(field.text, "")
        field.maximumLength = 48
        renderer(field)
      }
      function test_z_capture_synthetic_fields() {
        if (!Quickshell.env("SAFE_FIELD_TEST_IMAGE")) return
        field.text = "Work or Gaming"
        coordinate.text = "120"
        colorField.text = "#7aa2f7"
        colorField.forceActiveFocus()
        wait(100)
        var saved = false
        preview.grabToImage(function(result) { saved = result.saveToFile(Quickshell.env("SAFE_FIELD_TEST_IMAGE")) })
        tryVerify(function() { return saved }, 2000)
      }
    }
  }
}
