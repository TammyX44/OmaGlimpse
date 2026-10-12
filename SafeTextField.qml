import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// SECURITY: the native TextField below is ALWAYS readOnly. Qt 6.12's
// QQuickTextInput::q_canPasteChanged short-circuits on m_readOnly before asking
// the foreign clipboard mimeData()->hasText(). Visibility/focus guards alone
// cannot prevent that implicit read. Never enable native edits or native paste.
// Keyboard edits use programmatic text assignment; only explicit Ctrl+V /
// Shift+Insert starts the bounded helper. Native selection/navigation are safe.
// A read-only renderer does not support native IME/preedit composition. Direct
// Unicode key text works, but IME, compose/dead-key and AT editing need native QA.
FocusScope {
  id: root

  property alias text: renderer.text
  property alias placeholderText: renderer.placeholderText
  property alias font: renderer.font
  property alias color: renderer.color
  property alias horizontalAlignment: renderer.horizontalAlignment
  property alias verticalAlignment: renderer.verticalAlignment
  property alias selectByMouse: renderer.selectByMouse
  property alias cursorPosition: renderer.cursorPosition
  readonly property int selectionStart: renderer.selectionStart
  readonly property int selectionEnd: renderer.selectionEnd
  readonly property string selectedText: renderer.selectedText
  property int maximumLength: 4096
  property alias maxLength: root.maximumLength
  // JS RegExp against the whole proposed string; permits intermediate values.
  property var allowedPattern: null
  property bool framed: true
  property bool hostActive: true
  property string pasteError: ""
  readonly property bool pastePending: _job !== null
  readonly property bool canUndo: _undo.length > 0
  readonly property bool canRedo: _redo.length > 0
  readonly property int _limit: Math.max(0, Math.min(16384, maximumLength))
  property var _job: null
  property var _undo: []
  property var _redo: []
  property bool _changing: false
  property int _revision: 0
  property bool _hadFocus: false

  signal editingFinished()
  signal accepted()
  signal textEdited()
  signal pasteRejected(string reason)

  implicitWidth: renderer.implicitWidth
  implicitHeight: renderer.implicitHeight
  activeFocusOnTab: true
  Accessible.role: Accessible.EditableText
  Accessible.editable: true
  Accessible.readOnly: false // accessibility metadata ONLY; renderer stays readOnly
  Accessible.focusable: true
  Accessible.focused: activeFocus
  Accessible.selectable: true
  Accessible.description: pasteError

  function select(start, end) { renderer.select(start, end) }
  function selectAll() { renderer.selectAll() }
  function deselect() { renderer.deselect() }

  function bounded(value, length) {
    var s = String(value).replace(/\r\n|[\r\n\t\v\f\u0085\u2028\u2029]/g, " ")
                         .replace(/[\x00-\x08\x0e-\x1f\x7f-\x84\x86-\x9f]/g, "")
    var clean = ""
    for (var i = 0; i < s.length && clean.length < length; i++) {
      var code = s.charCodeAt(i)
      if (code >= 0xd800 && code <= 0xdbff) {
        var low = s.charCodeAt(i + 1)
        if (!(low >= 0xdc00 && low <= 0xdfff)) continue
        if (clean.length + 2 > length) break
        clean += s.substring(i, i + 2)
        i++
      } else if (code < 0xdc00 || code > 0xdfff) clean += s.charAt(i)
    }
    return clean // also remove orphan surrogates from native setter truncation
  }
  function permitted(value) {
    if (!allowedPattern) return true
    allowedPattern.lastIndex = 0
    var match = allowedPattern.exec(value)
    allowedPattern.lastIndex = 0
    return match !== null && match.index === 0 && match[0].length === value.length
  }
  function snapshot() {
    return { text: text, start: selectionStart, end: selectionEnd, cursor: cursorPosition }
  }
  function restore(state) {
    _changing = true
    renderer.text = bounded(state.text, _limit)
    if (state.start !== state.end) {
      if (state.cursor === state.start) renderer.select(state.end, state.start)
      else renderer.select(state.start, state.end)
    } else renderer.cursorPosition = Math.min(state.cursor, text.length)
    _changing = false
    textEdited()
  }
  function replaceRange(start, end, value) {
    cancelPaste()
    var insertion = bounded(value, _limit - (text.length - (end - start)))
    var next = text.substring(0, start) + insertion + text.substring(end)
    if (!permitted(next)) return false
    if (next === text) return true
    _undo = _undo.concat([snapshot()]).slice(-32)
    _redo = []
    _changing = true
    renderer.text = next
    renderer.cursorPosition = start + insertion.length
    renderer.deselect()
    _changing = false
    pasteError = ""
    textEdited()
    return true
  }
  function insertText(value) { return replaceRange(selectionStart, selectionEnd, value) }
  function previousPosition(pos) {
    if (pos > 1 && text.charCodeAt(pos - 1) >= 0xdc00 && text.charCodeAt(pos - 1) <= 0xdfff
        && text.charCodeAt(pos - 2) >= 0xd800 && text.charCodeAt(pos - 2) <= 0xdbff) return pos - 2
    return Math.max(0, pos - 1)
  }
  function nextPosition(pos) {
    if (pos + 1 < text.length && text.charCodeAt(pos) >= 0xd800 && text.charCodeAt(pos) <= 0xdbff
        && text.charCodeAt(pos + 1) >= 0xdc00 && text.charCodeAt(pos + 1) <= 0xdfff) return pos + 2
    return Math.min(text.length, pos + 1)
  }
  function erase(backwards) {
    var start = selectionStart, end = selectionEnd
    if (start === end) {
      start = backwards ? previousPosition(cursorPosition) : cursorPosition
      end = backwards ? cursorPosition : nextPosition(cursorPosition)
    }
    return replaceRange(start, end, "")
  }
  function undo() {
    cancelPaste()
    if (!canUndo) return
    _redo = _redo.concat([snapshot()]).slice(-32)
    var state = _undo[_undo.length - 1]
    _undo = _undo.slice(0, -1)
    restore(state)
  }
  function redo() {
    cancelPaste()
    if (!canRedo) return
    _undo = _undo.concat([snapshot()]).slice(-32)
    var state = _redo[_redo.length - 1]
    _redo = _redo.slice(0, -1)
    restore(state)
  }
  function copySelection() {
    // Explicit copy writes only this selection; it does not inspect foreign data.
    if (selectedText) renderer.copy()
  }
  function cutSelection() {
    if (!selectedText) return
    copySelection()
    replaceRange(selectionStart, selectionEnd, "")
  }
  function rejectPaste(code) {
    var messages = {
      "oversize": "Clipboard text exceeds 16 KiB. Copy a shorter value and try again.",
      "timeout": "Clipboard did not respond within 2 seconds. Copy the value again and retry.",
      "wrong-kind": "Clipboard does not contain plain text. Copy a text value and try again.",
      "invalid-utf8": "Clipboard text has invalid UTF-8. Copy the value again and retry.",
      "unavailable": "Clipboard helper is unavailable. Type the value or install wl-clipboard.",
      "pattern": "Clipboard text is not valid for this field. Check the value and try again."
    }
    pasteError = messages[code] || "Paste failed. Copy the value again or type it here."
    pasteRejected(pasteError)
  }
  function cancelPaste() {
    if (!_job) return
    _job.cancelled = true
    if (_job.running) _job.signal(15)
  }
  function requestPaste() {
    if (!enabled || !visible || !hostActive || !activeFocus || _job) return
    pasteError = ""
    _job = pasteJob.createObject(root, {
      revision: _revision, before: text, start: selectionStart, end: selectionEnd,
      command: ["python3", decodeURIComponent(String(Qt.resolvedUrl("bounded-clipboard.py")).replace(/^file:\/\//, "")),
                "--max-length", String(_limit)]
    })
    _job.running = true
  }
  function finishPaste(job) {
    if (!job.outputReady || !job.exitReady) return
    if (_job === job) _job = null
    var current = !job.cancelled && enabled && visible && hostActive && activeFocus
               && job.revision === _revision && job.before === text
               && job.start === selectionStart && job.end === selectionEnd
    if (current) {
      try {
        if (job.output.length > 32896) throw new Error("oversize")
        var response = JSON.parse(job.output)
        if (!response || response.version !== 1 || typeof response.ok !== "boolean") throw new Error("failed")
        if (!response.ok) throw new Error(typeof response.error === "string" ? response.error : "failed")
        if (job.exitCode !== 0 || typeof response.text !== "string" || response.text.length > 16384) throw new Error("failed")
        if (!insertText(response.text)) rejectPaste("pattern")
      } catch (error) { rejectPaste(String(error.message || "failed")) }
    }
    job.destroy()
  }
  onTextChanged: {
    _revision++
    cancelPaste()
    if (!_changing) {
      _undo = []; _redo = []
      var normalized = bounded(text, _limit)
      if (normalized !== text) {
        _changing = true
        renderer.text = normalized
        _changing = false
      }
    }
  }
  onMaximumLengthChanged: {
    cancelPaste()
    _undo = []; _redo = []
    if (text.length > _limit) renderer.text = bounded(text, _limit)
  }
  onAllowedPatternChanged: { cancelPaste(); _undo = []; _redo = [] }
  onActiveFocusChanged: {
    if (activeFocus) _hadFocus = true
    else {
      cancelPaste()
      if (_hadFocus) { _hadFocus = false; editingFinished() }
    }
  }
  onVisibleChanged: if (!visible) cancelPaste()
  onEnabledChanged: if (!enabled) cancelPaste()
  onHostActiveChanged: if (!hostActive) cancelPaste()
  Component.onDestruction: cancelPaste()

  Ui.PanelToolTip {
    id: pasteTip
    objectName: "safePasteErrorTooltip"
    visible: root.pasteError !== "" && root.activeFocus && root.visible && root.hostActive
    delay: 0
    text: root.pasteError
    width: Math.min(360, Math.max(240, root.width))
    contentItem: Text {
      text: pasteTip.text
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: pasteTip.panelForeground
      font.family: pasteTip.fontFamily
      font.pixelSize: pasteTip.fontSize
      leftPadding: Border.left(pasteTip.panelBorderSpec) + Style.spacing.controlPaddingX
      rightPadding: Border.right(pasteTip.panelBorderSpec) + Style.spacing.controlPaddingX
      topPadding: Border.top(pasteTip.panelBorderSpec) + Style.spacing.controlPaddingY
      bottomPadding: Border.bottom(pasteTip.panelBorderSpec) + Style.spacing.controlPaddingY
    }
  }

  Ui.TextField {
    id: renderer
    objectName: "safeTextRenderer"
    anchors.fill: parent
    // Do not alias or bind this to any caller-supplied property.
    readOnly: true
    focus: true
    activeFocusOnTab: false
    cursorVisible: activeFocus && root.enabled
    maximumLength: root._limit
    selectByMouse: true
    Accessible.ignored: true
    horizontalPadding: root.framed ? Style.spacing.controlPaddingX : 0
    verticalPadding: root.framed ? Style.spacing.inputPaddingY : 0
    leftPadding: root.framed ? horizontalPadding + Border.left(_borderSpec) : 0
    rightPadding: root.framed ? horizontalPadding + Border.right(_borderSpec) : 0
    topPadding: root.framed ? verticalPadding + Border.top(_borderSpec) : 0
    bottomPadding: root.framed ? verticalPadding + Border.bottom(_borderSpec) : 0
    background: Ui.BorderSurface {
      visible: root.framed
      color: Style.controlFill(renderer.activeFocus, renderer.hovered, renderer.foreground, renderer.accent)
      borderSpec: renderer._borderSpec
      radius: Style.cornerRadius
    }
    onCursorPositionChanged: { root._revision++; root.cancelPaste() }
    onSelectionStartChanged: { root._revision++; root.cancelPaste() }
    onSelectionEndChanged: { root._revision++; root.cancelPaste() }
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      var ctrl = !!(event.modifiers & Qt.ControlModifier)
      var shift = !!(event.modifiers & Qt.ShiftModifier)
      var alt = !!(event.modifiers & Qt.AltModifier)
      event.accepted = true
      if (!root.enabled || !root.hostActive) return
      if ((ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) root.requestPaste()
      else if ((ctrl && event.key === Qt.Key_C) || (ctrl && event.key === Qt.Key_Insert)) root.copySelection()
      else if ((ctrl && event.key === Qt.Key_X) || (shift && event.key === Qt.Key_Delete)) root.cutSelection()
      else if (ctrl && event.key === Qt.Key_A) root.selectAll()
      else if (ctrl && event.key === Qt.Key_Z) { if (shift) root.redo(); else root.undo() }
      else if (ctrl && event.key === Qt.Key_Y) root.redo()
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.cancelPaste(); root.accepted(); root.editingFinished() }
      else if (event.key === Qt.Key_Backspace) root.erase(true)
      else if (event.key === Qt.Key_Delete) root.erase(false)
      else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Home
            || event.key === Qt.Key_End || event.key === Qt.Key_Up || event.key === Qt.Key_Down
            || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        root.cancelPaste()
        event.accepted = false // native glyph/word navigation and tab focus
      } else if (event.text && (!ctrl || alt) && event.text.charCodeAt(0) >= 32) root.insertText(event.text)
      // All other edit/paste shortcuts are consumed, even if currently unknown.
    }
  }

  Component {
    id: pasteJob
    Process {
      id: job
      property int revision: 0
      property string before: ""
      property int start: 0
      property int end: 0
      property bool cancelled: false
      property bool outputReady: false
      property bool exitReady: false
      property int exitCode: -1
      property string output: ""
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { job.output = text; job.outputReady = true; root.finishPaste(job) }
      }
      onExited: function(code, status) {
        job.exitCode = status === 0 ? code : -1
        job.exitReady = true
        root.finishPaste(job)
      }
      // Covers startup failure; the helper itself owns the strict 2s read bound.
      property Timer watchdog: Timer {
        interval: 2500; running: true
        onTriggered: {
          if (job.running) job.signal(15)
          if (root._job === job && !job.cancelled) root.rejectPaste("timeout")
          job.cancelled = true
          if (!job.running) {
            if (root._job === job) root._job = null
            job.destroy()
          }
        }
      }
    }
  }
}
