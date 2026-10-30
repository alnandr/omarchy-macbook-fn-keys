import QtQuick
import Quickshell
import Quickshell.Io

// Headless owner of the function-row state. The bar widget (one per monitor)
// reads from here so every bar shows the same mode and one toggle at a time
// runs.
//
// Process hygiene: every child is started by absolute path with the inherited
// environment cleared. Privileged and inhibitor children get a fixed minimal
// PATH only; the setup terminal gets an allowlist of session variables. Output
// is bounded to one line, the helper call has a hard deadline, and every
// child is torn down explicitly when the plugin unloads.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string pluginId: "io.github.alnandr.macbook-fn-keys"
  readonly property string helper: "/usr/local/libexec/omarchy-mac-fnmode"
  readonly property string parameterPath: "/sys/module/hid_apple/parameters/fnmode"
  readonly property string setupScript: localPath(Qt.resolvedUrl("scripts/setup"))

  readonly property string sudoBin: "/usr/bin/sudo"
  readonly property string inhibitBin: "/usr/bin/systemd-inhibit"
  readonly property string catBin: "/usr/bin/cat"
  readonly property string terminalBin: "/usr/bin/omarchy-launch-floating-terminal-with-presentation"

  // Fixed environment for children that need no session access.
  readonly property var minimalEnvironment: ({ "PATH": "/usr/bin:/usr/sbin" })

  // The setup terminal needs the Wayland session and D-Bus, nothing more.
  // Only these names are forwarded from the shell's environment.
  readonly property var sessionEnvironmentAllowlist: [
    "HOME", "USER", "LOGNAME", "LANG", "SHELL", "TERMINAL",
    "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "XDG_SESSION_ID", "XDG_SEAT",
    "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_CONFIG_HOME",
    "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "XDG_STATE_HOME",
    "XDG_CACHE_HOME", "WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
    "HYPRLAND_INSTANCE_SIGNATURE", "OMARCHY_PATH"
  ]

  // Hard deadline for one helper call. sudo -n never prompts, and the helper
  // does two small writes, so anything past this is stuck.
  readonly property int helperDeadlineMs: 10000
  readonly property int helperKillGraceMs: 2000

  // "media"  fnmode=1: printed keys (brightness, volume, media) without Fn
  // "fkeys"  fnmode=2: F1-F12 without Fn
  // "other"  fnmode=0 or 3
  // "unavailable"  hid_apple is not loaded on this machine
  property string mode: "unavailable"
  property bool available: false
  // The root helper is installed. The sudoers rule cannot be read as a user,
  // so a refused toggle sets sudoDenied instead.
  property bool setupDone: false
  property bool sudoDenied: false
  property bool busy: false
  property string lastError: ""

  readonly property bool ready: available && setupDone && !sudoDenied

  // Bounded output from the last helper call: first stdout line, last stderr line.
  property string helperStdoutLine: ""
  property string helperStderrLine: ""

  function localPath(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

  function sessionEnvironment() {
    var env = { "PATH": "/usr/share/omarchy/bin:/usr/bin:/usr/sbin" }
    for (var i = 0; i < sessionEnvironmentAllowlist.length; i++) {
      var name = sessionEnvironmentAllowlist[i]
      var value = Quickshell.env(name)
      if (value !== undefined && value !== null && String(value).length > 0)
        env[name] = String(value)
    }
    return env
  }

  function refresh() {
    parameterFile.reload()
    helperFile.reload()
  }

  function applyParameter(text) {
    var value = String(text).trim()
    available = true
    if (value === "1") mode = "media"
    else if (value === "2") mode = "fkeys"
    else mode = "other"
  }

  function setMode(target) {
    // Any explicit switch, by the user or the boot sync itself, ends the boot sync.
    bootSyncDone = true
    if (busy || !available) return
    if (target !== 1 && target !== 2) return
    busy = true
    lastError = ""
    helperStdoutLine = ""
    helperStderrLine = ""
    setProcess.command = [sudoBin, "-n", "--", helper, String(target)]
    setProcess.running = true
    deadlineTimer.restart()
  }

  function toggle() {
    setMode(mode === "media" ? 2 : 1)
  }

  // Setup needs the user's password once, so it runs in Omarchy's floating
  // terminal rather than silently from the shell process.
  function runSetup() {
    Quickshell.execDetached({
      command: [terminalBin, setupScript],
      clearEnvironment: true,
      environment: sessionEnvironment()
    })
  }

  function finishHelper(exitCode) {
    deadlineTimer.stop()
    killTimer.stop()
    busy = false
    if (exitCode === 0) {
      sudoDenied = false
      var label = helperStdoutLine.trim()
      if (label === "media" || label === "fkeys") mode = label
    } else {
      var error = helperStderrLine.trim()
      // sudo -n reports a missing rule as "a password is required".
      sudoDenied = error.indexOf("password") !== -1 || error.indexOf("sudo:") === 0
      lastError = error || "helper exited with status " + exitCode
    }
    refresh()
  }

  function teardown() {
    deadlineTimer.stop()
    killTimer.stop()
    if (setProcess.running) {
      setProcess.signal(9)
      setProcess.running = false
    }
    // Closing stdin gives cat EOF, which ends systemd-inhibit and releases the
    // inhibitor even if the signal below were lost.
    suspendKeyInhibitor.stdinEnabled = false
    if (suspendKeyInhibitor.running) {
      suspendKeyInhibitor.signal(15)
      suspendKeyInhibitor.running = false
    }
  }

  Component.onCompleted: refresh()
  Component.onDestruction: teardown()

  // sysfs does not deliver inotify events, so the kernel value is polled. It
  // only changes through the helper or a manual write, so a slow poll is
  // enough; toggles update the mode immediately from the helper's reply.
  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  FileView {
    id: parameterFile
    path: root.parameterPath
    printErrors: false
    onLoaded: root.applyParameter(text())
    onFileChanged: root.applyParameter(text())
    onLoadFailed: {
      root.available = false
      root.mode = "unavailable"
    }
  }

  // hid_apple is often loaded from the initramfs (mkinitcpio keyboard +
  // modconf hooks), which carries a stale copy of modprobe.d, so the mode
  // chosen here would be lost on reboot. Re-apply the persisted mode once per
  // shell start instead of rebuilding the initramfs on every toggle.
  readonly property string persistentPath: "/etc/modprobe.d/hid_apple.conf"
  property string persistedMode: ""
  property bool bootSyncDone: false

  function syncPersistedMode() {
    if (bootSyncDone || !ready || busy || persistedMode === "" || mode === "unavailable") return
    bootSyncDone = true
    if (persistedMode === "1" && mode !== "media") setMode(1)
    else if (persistedMode === "2" && mode !== "fkeys") setMode(2)
  }

  onReadyChanged: syncPersistedMode()
  onModeChanged: syncPersistedMode()
  onPersistedModeChanged: syncPersistedMode()

  FileView {
    id: persistentFile
    path: root.persistentPath
    printErrors: false
    onLoaded: {
      var match = /^\s*options\s+hid_apple\s+.*\bfnmode=([12])\b/m.exec(text())
      root.persistedMode = match ? match[1] : ""
    }
  }

  FileView {
    id: helperFile
    path: root.helper
    printErrors: false
    onLoaded: root.setupDone = true
    onLoadFailed: root.setupDone = false
  }

  // In media mode F6 sends KEY_SLEEP, and logind's default HandleSuspendKey
  // would suspend the machine before Hyprland's Do Not Disturb binding ran.
  // Hold a suspend-key inhibitor only while that mode is active. The child is
  // cat with an open stdin: it exits on EOF, so the inhibitor is released when
  // this process closes the pipe, whether by toggle, unload, or shell exit.
  Process {
    id: suspendKeyInhibitor
    running: root.available && root.mode === "media"
    stdinEnabled: true
    clearEnvironment: true
    environment: root.minimalEnvironment
    command: [
      root.inhibitBin,
      "--what=handle-suspend-key",
      "--who=MacBook Function Keys",
      "--why=F6 is Do Not Disturb while the function row sends media keys",
      "--mode=block",
      root.catBin
    ]
  }

  Process {
    id: setProcess
    clearEnvironment: true
    environment: root.minimalEnvironment
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (root.helperStdoutLine === "") root.helperStdoutLine = String(line).slice(0, 256)
      }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var text = String(line).trim()
        if (text.length > 0) root.helperStderrLine = text.slice(0, 512)
      }
    }
    onExited: function(exitCode) {
      root.finishHelper(exitCode)
    }
  }

  // Deadline: ask nicely, then kill. finishHelper runs from onExited either way.
  Timer {
    id: deadlineTimer
    interval: root.helperDeadlineMs
    repeat: false
    onTriggered: {
      if (!setProcess.running) return
      root.helperStderrLine = "helper did not finish within " + (root.helperDeadlineMs / 1000) + "s"
      setProcess.signal(15)
      killTimer.restart()
    }
  }

  Timer {
    id: killTimer
    interval: root.helperKillGraceMs
    repeat: false
    onTriggered: {
      if (setProcess.running) setProcess.signal(9)
    }
  }
}
