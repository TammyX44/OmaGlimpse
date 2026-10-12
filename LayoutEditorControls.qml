import QtQuick
import qs.Commons
import qs.Ui
import "LayoutProfiles.js" as Profiles

Column {
  id: editor
  property var config: ({})
  property var displayInventory: []
  property string selectedDisplay: ""
  property bool undoAvailable: false
  property bool hostActive: false
  property int dismissRevision: 0
  property string statusText: ""
  property string selectedLayout: ""
  property string armedAction: ""
  readonly property var options: config.editor || {}
  readonly property var names: Object.keys(config.namedLayouts || {}).sort()
  signal editorChanged(string key, var value)
  signal displaySelected(string name)
  signal undoRequested()
  signal namedLayoutRequested(string name, string action)
  spacing: 10
  onHostActiveChanged: if (!hostActive) armedAction = ""
  onNamesChanged: if (names.indexOf(selectedLayout) === -1) selectedLayout = names.length ? names[0] : ""

  PanelSectionHeader { width: parent.width; text: "LAYOUT EDITOR" }
  Text {
    width: parent.width; wrapMode: Text.WordWrap
    text: "Each monitor setup remembers its own arrangement, including resolution and scaling."
    color: Color.foreground; font.family: Style.font.family; font.pixelSize: 12
    textFormat: Text.PlainText
  }
  Text { text: "Widget display"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: 12 }
  WidgetDropdown {
    objectName: "layoutDisplayPicker"
    width: parent.width; height: 34
    value: editor.selectedDisplay
    hostActive: editor.hostActive; dismissRevision: editor.dismissRevision
    options: editor.displayInventory.map(function(s) {
      return { value: s.name, label: s.name + " · " + s.width + " × " + s.height + " · " + Math.round(s.scale * 100) + "%" }
    })
    onChanged: function(value) { editor.displaySelected(value) }
  }
  Toggle {
    width: parent.width; label: "Snap to grid"
    description: "Place cards on a consistent grid while dragging."
    checked: editor.options.snapToGrid !== false
    onClicked: editor.editorChanged("snapToGrid", !checked)
  }
  Row {
    width: parent.width; height: 32; spacing: 10
    visible: editor.options.snapToGrid !== false
    Text { width: 80; anchors.verticalCenter: parent.verticalCenter; text: "Grid size"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: 12 }
    PanelSlider {
      width: Math.max(60, parent.width - 148); height: 32
      value: Number(editor.options.gridSize) || 8
      minimum: 4; maximum: 32; step: 4; integer: true
      onMoved: editor.editorChanged("gridSize", Math.round(value))
    }
    Text { width: 48; anchors.verticalCenter: parent.verticalCenter; text: (Number(editor.options.gridSize) || 8) + " px"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: 12 }
  }
  Toggle {
    width: parent.width; label: "Alignment guides"
    description: "Snap to card edges and centres, using Card Spacing for gaps."
    checked: editor.options.snapToCards !== false
    onClicked: editor.editorChanged("snapToCards", !checked)
  }
  Button {
    objectName: "undoLayoutButton"
    width: parent.width; height: 34; text: "Undo last layout change"
    bordered: true; focusable: true; enabled: editor.undoAvailable
    onClicked: editor.undoRequested()
  }
  Text { text: "Named layouts"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: 12 }
  Rectangle {
    width: parent.width; height: 36; radius: 6
    color: Color.background
    border.width: 1; border.color: nameInput.activeFocus ? Color.accent : Color.popups.border
    SafeTextField {
      id: nameInput
      objectName: "layoutNameInput"
      anchors.fill: parent; anchors.margins: 9
      color: Color.foreground; font.family: Style.font.family; font.pixelSize: 12
      maximumLength: 48; selectByMouse: true; clip: true; framed: false
      Accessible.name: "New layout name"
      onTextChanged: editor.armedAction = ""
      Text { anchors.fill: parent; visible: !nameInput.text; text: "e.g. Work or Gaming"; color: Color.foreground; opacity: 0.65; font: nameInput.font }
    }
  }
  Button {
    objectName: "saveNamedLayoutButton"
    width: parent.width; height: 34; bordered: true; focusable: true
    readonly property string layoutName: Profiles.safeName(nameInput.text)
    readonly property bool exists: editor.names.indexOf(layoutName) !== -1
    enabled: !!layoutName && ["__proto__", "constructor", "prototype"].indexOf(layoutName) === -1
    text: exists ? (editor.armedAction === "save:" + layoutName ? "Confirm replace layout" : "Replace saved layout…") : "Save current layout"
    onClicked: {
      if (exists && editor.armedAction !== "save:" + layoutName) { editor.armedAction = "save:" + layoutName; return }
      editor.namedLayoutRequested(layoutName, "save")
      editor.selectedLayout = layoutName
      editor.armedAction = ""
    }
  }
  WidgetDropdown {
    width: parent.width; height: 34; visible: editor.names.length > 0
    value: editor.selectedLayout
    hostActive: editor.hostActive; dismissRevision: editor.dismissRevision
    options: editor.names.map(function(name) { return { value: name, label: name } })
    onChanged: function(value) { editor.selectedLayout = value; editor.armedAction = "" }
  }
  Row {
    width: parent.width; spacing: 8; visible: editor.names.length > 0
    Button {
      width: (parent.width - 8) / 2; height: 34; text: "Load layout"
      bordered: true; focusable: true; enabled: !!editor.selectedLayout
      onClicked: editor.namedLayoutRequested(editor.selectedLayout, "load")
    }
    Button {
      width: (parent.width - 8) / 2; height: 34
      text: editor.armedAction === "delete:" + editor.selectedLayout ? "Confirm delete" : "Delete…"
      bordered: true; focusable: true; enabled: !!editor.selectedLayout
      onClicked: {
        if (editor.armedAction !== "delete:" + editor.selectedLayout) { editor.armedAction = "delete:" + editor.selectedLayout; return }
        editor.namedLayoutRequested(editor.selectedLayout, "delete")
        editor.armedAction = ""
      }
    }
  }
  Text {
    width: parent.width; visible: !!editor.statusText
    text: editor.statusText; textFormat: Text.PlainText; wrapMode: Text.WordWrap
    color: Color.foreground; font.family: Style.font.family; font.pixelSize: 11
  }
}
