import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import "../code/CleanerModel.js" as Model

// The keyboard cleaner for Plasma: every key off while you wipe, and always back on.
//
// The guard (bin/keyboard-cleaner, the same one as on Omarchy) switches KWin's keyboards off over D-Bus and
// gives them back at the deadline, on a signal, when Plasma goes, or when `restore` takes its record away -- and a
// watchdog in its own session does it even if the guard was killed. This widget starts the guard, draws the
// countdown over every screen, and runs `restore` when it loads and when you hold the ring.
PlasmoidItem {
  id: root

  readonly property string code: decodeURIComponent(String(Qt.resolvedUrl("../code")).replace("file://", ""))
  readonly property string envPrefix: "/usr/bin/env -i HOME=\"$HOME\" PATH=/usr/bin:/bin LANG=C.UTF-8"
    + " XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\" XDG_CURRENT_DESKTOP=\"$XDG_CURRENT_DESKTOP\""
    // Only when set: an empty bus address makes busctl fail where leaving it out lets it find the bus.
    + " ${DBUS_SESSION_BUS_ADDRESS:+DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\"} "
  readonly property string helper: root.envPrefix + "/usr/bin/python3 -I '" + root.code.replace(/'/g, "'\\''") + "/bin/keyboard-cleaner'"
  readonly property int seconds: Model.clampSeconds(Plasmoid.configuration.seconds, Model.DEFAULT_SECONDS)

  P5Support.DataSource {
    id: runner
    engine: "executable"
    property var onDone: ({})
    onNewData: function (source, data) {
      disconnectSource(source)
      var cb = runner.onDone[source]
      delete runner.onDone[source]
      if (cb) cb(Number(data["exit code"]), String(data["stdout"] || "").slice(0, 65536))
    }
  }

  function run(command, done) {
    var key = command + " # " + Date.now() + Math.random()
    runner.onDone[key] = done || null
    runner.connectSource(key)
  }

  // A lock a crashed Plasma left behind is given back whenever the widget loads.
  Component.onCompleted: root.run(root.helper + " restore", null)

  // ---------------------------------------------------------------- cleaning

  property string phase: "idle"       // idle | locked | unlocking | failed
  property string message: ""
  property double startedAt: 0
  property double deadlineAt: 0
  property string guardCommand: ""

  // The guard's only news is that it stopped: its events arrive together, at the end.
  P5Support.DataSource {
    id: guard
    engine: "executable"
    onNewData: function (source, data) {
      if (source !== root.guardCommand) return
      disconnectSource(source)
      root.guardCommand = ""
      var lines = String(data["stdout"] || "").split("\n")
      var error = ""
      for (var i = 0; i < lines.length; i++) {
        var e = Model.parseEvent(lines[i])
        if (e && e.event === "error") error = e.message
      }
      var ok = Number(data["exit code"]) === 0
      if (!ok && !error) {
        // It locked, and then could not give everything back: try again, and say so plainly if that fails too.
        root.run(root.helper + " restore", function (code) {
          if (code === 0) { root.phase = "idle"; return }
          root.phase = "failed"
          root.message = "The keyboard may still be off. Use the mouse: right click the widget, or run its restore."
          failedTimer.restart()
          root.run("/usr/bin/notify-send --app-name='Keyboard cleaner' --icon=input-keyboard --urgency=critical -- "
                   + "'The keyboard may still be off' "
                   + root.quote("Run: /usr/bin/python3 " + root.code + "/bin/keyboard-cleaner restore"), null)
        })
      } else if (error) {
        root.phase = "failed"
        root.message = error
        failedTimer.restart()
      } else {
        root.phase = "idle"
      }
    }
  }

  Timer { id: failedTimer; interval: 4000; onTriggered: if (root.phase === "failed") root.phase = "idle" }

  function clean(seconds) {
    if (root.phase === "locked" || root.phase === "unlocking") return
    var s = Model.clampSeconds(seconds, root.seconds)
    root.expanded = false
    root.message = ""
    root.startedAt = Date.now()
    root.deadlineAt = root.startedAt + s * 1000
    root.phase = "locked"
    root.guardCommand = root.helper + " lock " + s + " --no-stdin"
    guard.connectSource(root.guardCommand)
  }

  // Held on the ring for three seconds: `restore` switches everything back on and takes the record, which ends the
  // guard within a second.
  function unlock() {
    if (root.phase !== "locked") return
    root.phase = "unlocking"
    root.message = ""
    root.run(root.helper + " restore", function (code) {
      // Not given back yet (KWin did not answer, say): back to the ring, so the hold can be tried again.
      if (code !== 0 && root.phase === "unlocking") {
        root.phase = "locked"
        root.message = "The keyboard could not be given back yet. Hold the ring again."
      }
    })
  }

  function quote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  // Past the deadline and its grace the guard should long be gone; ask it to stop.
  Timer {
    interval: 1000
    repeat: true
    running: root.phase === "locked" || root.phase === "unlocking"
    onTriggered: if (Date.now() > root.deadlineAt + Model.OVERDUE_MS && root.guardCommand !== "") {
      guard.disconnectSource(root.guardCommand)
      root.guardCommand = ""
      root.phase = "idle"
      root.run(root.helper + " restore", null)
    }
  }

  Loader {
    active: root.phase !== "idle"
    sourceComponent: Overlay { cleaner: root }
  }

  // ---------------------------------------------------------------- the widget

  Plasmoid.icon: "input-keyboard"
  toolTipMainText: "Keyboard cleaner"
  toolTipSubText: "Switch every key off while you wipe the keyboard"

  fullRepresentation: PlasmaExtras.Representation {
    Layout.preferredWidth: Kirigami.Units.gridUnit * 16
    Layout.preferredHeight: implicitHeight
    implicitHeight: column.implicitHeight + Kirigami.Units.largeSpacing * 2

    ColumnLayout {
      id: column
      anchors.fill: parent
      anchors.margins: Kirigami.Units.largeSpacing
      spacing: Kirigami.Units.smallSpacing

      Kirigami.Heading {
        level: 3
        textFormat: Text.PlainText
        text: "Clean the keyboard"
      }
      PlasmaComponents.Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        opacity: 0.7
        text: "Every key goes off; the mouse and touchpad stay on. Hold a click on the ring for 3 seconds to unlock early."
      }
      Repeater {
        model: [{ s: root.seconds, label: "For " + Model.formatClock(root.seconds * 1000, false) + " (your default)" },
                { s: 60, label: "For 1 minute" }, { s: 120, label: "For 2 minutes" }, { s: 300, label: "For 5 minutes" }]
        delegate: PlasmaComponents.Button {
          required property var modelData
          Layout.fillWidth: true
          icon.name: "input-keyboard"
          text: modelData.label
          onClicked: root.clean(modelData.s)
        }
      }
    }
  }
}
