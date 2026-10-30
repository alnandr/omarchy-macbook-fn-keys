import QtQuick
import qs.Ui

// Bar toggle for the MacBook function row. State lives in Service.qml so all
// bars agree; this file only paints it and forwards clicks.
BarWidget {
  id: root
  moduleName: "io.github.alnandr.macbook-fn-keys"

  // Omarchy 4.x hands third-party widgets a scoped PluginShellApi
  // (bar.shell.serviceFor) instead of ShellRoot, so _services is not
  // reachable. The lookup is not reactive, so retry until the shell has
  // created the service.
  property var service: null
  function lookupService() {
    var shell = bar ? bar.shell : null
    var found = shell && typeof shell.serviceFor === "function" ? shell.serviceFor(moduleName) : null
    if (found !== service) service = found
  }
  onBarChanged: lookupService()
  Component.onCompleted: lookupService()
  Timer {
    interval: 500
    repeat: true
    running: !root.service
    onTriggered: root.lookupService()
  }
  readonly property bool available: service ? service.available : false
  readonly property bool ready: service ? service.ready : false
  readonly property string mode: service ? service.mode : "unavailable"

  // The bar's panel routing expects these on every widget it can focus.
  readonly property bool opened: false
  readonly property bool popoutSwitchClosing: false
  function open() {}
  function close() {}
  function closeForPopoutSwitch() {}

  readonly property string glyph: {
    if (!ready) return "󰌌"
    if (mode === "media") return "󰃞"
    if (mode === "fkeys") return "󰡀"
    return "?"
  }

  readonly property string tooltip: {
    if (!service) return "Function keys service is loading"
    if (!available) return "This keyboard is not driven by hid_apple"
    if (!service.setupDone) return "Function keys: click to run the one-time setup"
    if (service.sudoDenied) return "Function keys: setup is incomplete, click to run it again"
    if (service.busy) return "Switching function-row mode"
    if (mode === "media") return "Function row sends brightness, volume and media. Click for F1-F12."
    if (mode === "fkeys") return "Function row sends F1-F12. Click for brightness, volume and media."
    return "Function row is in an unmanaged mode. Click for brightness, volume and media."
  }

  // Nothing to show on machines without an Apple keyboard.
  visible: available
  implicitWidth: available ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.tooltip
    dimmed: root.service ? root.service.busy : false
    onPressed: function(buttonCode) {
      if (buttonCode !== Qt.LeftButton || !root.service) return
      if (root.ready) root.service.toggle()
      else root.service.runSetup()
    }
  }
}
