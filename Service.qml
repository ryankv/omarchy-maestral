import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Talks to Maestral, the open-source Dropbox client, on behalf of Panel.qml.
//
// State comes from status.py, which asks the Maestral daemon (or, when it is
// not running, reads its saved state) and prints one JSON object. Control goes
// through control.sh: pause, resume, start (via the systemd user unit when it
// is enabled). Linking an account is interactive, so it runs in a floating
// terminal via link.sh.
Item {
  id: root

  property var settings: ({})
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool installed: false
  property bool daemonRunning: false
  property bool running: false
  property bool paused: false
  property bool authenticated: false

  // Optimistic sync state so the UI reacts the instant you click, rather than
  // waiting for Maestral to settle. _desired is -1 while we just follow the
  // real state, or 0/1 while a pause/resume is still catching up.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : (_desired === 1)
  property bool refreshing: false
  property string statusText: "Checking…"
  property string accountPath: ""
  property string email: ""
  property string plan: ""
  property int syncErrors: 0
  property double usedBytes: 0
  property double quotaBytes: 0
  property double usagePercent: 0
  property bool quotaKnown: false
  property var files: []
  property string actionStatus: ""
  property string lastError: ""
  property string executable: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property bool busy: statusProcess.running || controlProcess.running
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string helperPath: pluginDir + "/status.py"
  readonly property string linkScriptPath: pluginDir + "/link.sh"
  readonly property string controlScriptPath: pluginDir + "/control.sh"

  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlOutput: ""
  property string _controlError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = ["python3", helperPath, "25"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Failed to read Maestral status"
      return
    }
    installed = parsed.installed === true
    executable = String(parsed.executable || "")
    daemonRunning = parsed.daemonRunning === true
    running = parsed.running === true
    paused = parsed.paused === true
    authenticated = parsed.authenticated === true
    // Reality caught up to the pending pause/resume — stop overriding.
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    statusText = String(parsed.statusText || (installed ? "Stopped" : "Not installed"))
    accountPath = String(parsed.accountPath || "")
    email = String(parsed.email || "")
    plan = String(parsed.plan || "")
    syncErrors = Number(parsed.syncErrors || 0)
    usedBytes = Number(parsed.usedBytes || 0)
    quotaBytes = Number(parsed.quotaBytes || 0)
    usagePercent = Number(parsed.usagePercent || 0)
    quotaKnown = parsed.quotaKnown === true
    files = parsed.files || []
    lastError = ""
    if (authenticated && linkWatch.running) {
      linkWatch.running = false
      actionStatus = ""
    }
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  // Linking is a conversation (auth code, folder location, selective sync), so
  // hand it to a floating terminal and poll until the account shows up.
  function login() {
    if (!installed) return
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "bash", linkScriptPath])
    actionStatus = "Finish linking Dropbox in the terminal window"
    linkWatch.ticks = 0
    linkWatch.restart()
  }

  function pause() {
    runControl(["bash", controlScriptPath, "pause"], 0)
  }

  function resume() {
    runControl(["bash", controlScriptPath, daemonRunning ? "resume" : "start"], 1)
  }

  function toggleRunning() {
    if (active) pause()
    else resume()
  }

  function runControl(command, desired) {
    // No progress status here — the greyed icon and hero phrase already convey
    // the pause/resume; only surface a message if the command fails.
    if (!installed || controlProcess.running) return
    _desired = desired
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = command
    controlProcess.running = true
  }

  function openFile(file) {
    if (!file || !file.path) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", "--select", fileUri(String(file.path))])
  }

  function fileUri(path) {
    var parts = String(path || "").split("/")
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // After login the Maestral daemon comes up via systemd a little after the
    // shell polls, which left the icon stale until the next periodic refresh.
    // Poll quickly until the daemon shows up, or give up after ~30 seconds.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.daemonRunning || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    // While link.sh is open, poll every few seconds so the panel flips to the
    // account view as soon as linking completes. Stops after ten minutes.
    id: linkWatch
    property int ticks: 0
    interval: 3000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 200) {
        linkWatch.running = false
        root.actionStatus = ""
      }
    }
  }

  Timer {
    id: delayedRefresh
    interval: 1000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Maestral takes a moment to settle after pause/resume/start, so re-poll a
    // handful of times to reflect the new state without waiting for the next
    // periodic refresh.
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.refresh()
      if (settleTimer.ticks >= 4) {
        settleTimer.ticks = 0
        settleTimer.running = false
        root._desired = -1
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elideStatus(stderr || stdout || "Could not read Maestral status")
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector { id: controlStdout; waitForEnd: true; onStreamFinished: root._controlOutput = text }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true; onStreamFinished: root._controlError = text }
    onExited: function(exitCode) {
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elideStatus(stderr || stdout || "Maestral command failed")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      delayedRefresh.restart()
    }
  }
}
