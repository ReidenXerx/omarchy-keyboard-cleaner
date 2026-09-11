import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "CleanerModel.js" as Model

// Cleaning mode: every keyboard switched off in the compositor, a themed card on every
// screen, and only two ways out -- a click held still on the ring, or the timer.
//
// The guard helper owns the lock and every way of undoing it; this surface only shows it
// and asks for the keyboard back. It runs exactly two programs, both as argv lists:
// ["/usr/bin/python3", <plugin>/bin/keyboard-cleaner, ...].
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string python: "/usr/bin/python3"
  readonly property string helper: localPath("bin/keyboard-cleaner")
  readonly property string pluginId: (manifest && manifest.id) || "reidenxerx.keyboard-cleaner"

  function localPath(rel) {
    return decodeURIComponent(String(Qt.resolvedUrl(rel)).replace("file://", ""))
  }

  // ---------------------------------------------------------------- theme

  // The [menu] surface tokens, like Omarchy's own overlays, so every theme styles it.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color accent: Color.accent
  property color muted: Color.muted
  property color urgent: Color.urgent
  property string fontFamily: Style.font.menuFamily
  // Glyphs need the Nerd Font, which is what `monospace` resolves to.
  property string glyphFamily: Style.font.family

  // ---------------------------------------------------------------- state

  property string phase: "idle"     // idle | locking | locked | unlocking | failed
  property int seconds: Model.DEFAULT_SECONDS
  property real startedAt: 0
  property real deadline: 0
  property real now: Date.now()
  property int failedDevices: 0
  property string message: ""

  property bool holding: false
  property real holdStartedAt: 0
  property real holdX: 0
  property real holdY: 0
  property real holdProgress: 0

  readonly property real remainingMs: Math.max(0, deadline - now)

  // ---------------------------------------------------------------- shell contract

  function open(payloadJson) {
    if (root.opened || guard.running) return
    root.seconds = Model.secondsFromPayload(payloadJson)
    root.phase = "locking"
    root.message = ""
    root.failedDevices = 0
    root.startedAt = Date.now()
    root.now = root.startedAt
    root.deadline = root.startedAt + root.seconds * 1000
    root.cancelHold()
    root.opened = true
    guard.command = [root.python, root.helper, "lock", String(root.seconds)]
    guard.running = true
  }

  // The shell's hide() lands here. While locked it asks for the keyboard back rather than
  // just vanishing; the surface goes away when the guard reports everything is on again.
  function close() {
    if (guard.running) root.requestUnlock()
    else root.opened = false
  }

  function requestUnlock() {
    if (!guard.running || root.phase === "unlocking") return
    root.phase = "unlocking"
    root.cancelHold()
    guard.write("unlock\n")
    unlockTimeout.restart()
  }

  function hide() {
    failedHide.stop()
    root.phase = "idle"
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // ---------------------------------------------------------------- the guard

  Process {
    id: guard
    // Required: the guard treats a closed stdin as "the shell is gone" and unlocks at once.
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function (line) { root.onGuardEvent(line) }
    }
    onExited: function (exitCode, exitStatus) {
      unlockTimeout.stop()
      killTimer.stop()
      // However the guard ended -- normally, killed, or crashed -- make sure nothing is
      // left switched off. With no lock record this runs no tools at all.
      Quickshell.execDetached([root.python, root.helper, "restore"])
      if (exitCode !== 0 && root.phase !== "failed") {
        root.phase = "failed"
        root.message = "The lock ended unexpectedly. Keys come back within seconds."
      }
      root.cancelHold()
      if (root.phase === "failed") failedHide.restart()
      else root.hide()
    }
  }

  function onGuardEvent(line) {
    var e = Model.parseEvent(line)
    if (!e) return
    if (e.event === "locked") {
      root.failedDevices = e.failed
      root.deadline = e.deadlineMs
      if (root.phase === "locking") root.phase = "locked"
    } else if (e.event === "unlocked") {
      if (e.ok) root.phase = "unlocking"
      else {
        root.phase = "failed"
        root.message = "Some keys could not be switched back on yet. They return within seconds."
      }
    } else if (e.event === "error") {
      root.phase = "failed"
      root.message = e.message
    }
  }

  Timer {
    interval: 200
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: {
      root.now = Date.now()
      // The guard ends the lock at its deadline; this only covers one that wedged.
      if (guard.running && root.phase === "locked" && root.now > root.deadline + Model.OVERDUE_MS)
        root.requestUnlock()
    }
  }

  // SIGTERM if "unlock" was not honoured in time (the guard restores on SIGTERM too),
  // SIGKILL after that -- and then onExited's restore and the watchdog take over.
  Timer {
    id: unlockTimeout
    interval: 10000
    onTriggered: if (guard.running) { guard.signal(15); killTimer.restart() }
  }
  Timer {
    id: killTimer
    interval: 3000
    onTriggered: if (guard.running) guard.signal(9)
  }
  Timer {
    id: failedHide
    interval: 4500
    onTriggered: root.hide()
  }

  // Every shell start: a lock the last shell did not get to undo is undone now.
  Component.onCompleted: Quickshell.execDetached([root.python, root.helper, "restore"])
  Component.onDestruction: {
    if (guard.running) guard.write("unlock\n")
    Quickshell.execDetached([root.python, root.helper, "restore"])
  }

  // ---------------------------------------------------------------- hold to unlock

  function beginHold(x, y) {
    if (root.phase !== "locked") return
    root.holding = true
    root.holdStartedAt = Date.now()
    root.holdX = x
    root.holdY = y
    root.holdProgress = 0
  }

  function moveHold(x, y) {
    if (root.holding && Model.movedTooFar(root.holdX, root.holdY, x, y)) root.cancelHold()
  }

  function cancelHold() {
    root.holding = false
    root.holdProgress = 0
  }

  Timer {
    interval: 30
    repeat: true
    running: root.holding
    onTriggered: {
      root.holdProgress = Model.holdFraction(Date.now() - root.holdStartedAt)
      if (root.holdProgress >= 1) root.requestUnlock()
    }
  }

  // ---------------------------------------------------------------- ui

  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: surface
      required property var modelData
      readonly property bool primary: modelData === Quickshell.screens[0]

      screen: modelData
      visible: root.opened
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-keyboard-cleaner"
      WlrLayershell.layer: WlrLayer.Overlay
      // The keyboards are off in the compositor; this also keeps any virtual keyboard
      // from typing into the app underneath.
      WlrLayershell.keyboardFocus: surface.primary ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // A display that sleeps mid-clean would hide the countdown.
      IdleInhibitor {
        enabled: root.opened
        window: surface
      }

      Rectangle {
        anchors.fill: parent
        color: root.background
      }

      // Swallows every click, scroll and drag that is not a hold on the ring: this is what
      // makes wiping the touchpad do nothing.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onWheel: function (wheel) { wheel.accepted = true }
      }

      BorderSurface {
        id: card
        readonly property int ringSize: Math.min(Style.space(260), surface.height * 0.34)

        width: Math.min(Style.space(460), surface.width - Style.gapsOut * 4)
        height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
        radius: Style.cornerRadius
        anchors.centerIn: parent
        color: root.background
        borderSpec: root.borderSpec
        padding: Style.spacing.panelPadding

        Column {
          id: content
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.spacing.md

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // md-keyboard (U+F030C), checked against the Nerd Font's own charset.
            text: "󰌌"
            color: root.phase === "failed" ? root.urgent : root.accent
            font.family: root.glyphFamily
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Cleaning mode"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: Model.subtitle(root.phase, root.failedDevices, root.message)
            color: root.phase === "failed" ? root.urgent : root.foreground
            opacity: root.phase === "failed" ? 1 : 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Item {
            width: parent.width
            height: card.ringSize

            Canvas {
              id: ring
              width: card.ringSize
              height: width
              anchors.centerIn: parent
              readonly property real remaining: Model.remainingFraction(root.now, root.startedAt, root.deadline)
              readonly property real hold: root.holdProgress
              onRemainingChanged: requestPaint()
              onHoldChanged: requestPaint()
              onVisibleChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var c = width / 2
                var line = Math.max(4, width * 0.045)
                var r = c - line
                var top = -Math.PI / 2
                ctx.lineCap = "round"
                ctx.lineWidth = line

                ctx.globalAlpha = 0.14
                ctx.strokeStyle = String(root.foreground)
                ctx.beginPath()
                ctx.arc(c, c, r, 0, Math.PI * 2)
                ctx.stroke()

                ctx.globalAlpha = 1
                if (remaining > 0) {
                  ctx.strokeStyle = String(root.accent)
                  ctx.beginPath()
                  ctx.arc(c, c, r, top, top + Math.PI * 2 * remaining)
                  ctx.stroke()
                }
                if (hold > 0) {
                  ctx.lineWidth = line * 1.6
                  ctx.strokeStyle = String(root.foreground)
                  ctx.beginPath()
                  ctx.arc(c, c, r - line * 2.4, top, top + Math.PI * 2 * hold)
                  ctx.stroke()
                }
              }

              Column {
                anchors.centerIn: parent
                spacing: 0

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: Model.formatClock(root.remainingMs, true)
                  color: root.foreground
                  font.family: root.glyphFamily
                  font.pixelSize: Math.round(card.ringSize * 0.22)
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.phase === "locked" ? "left" : ""
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // The one place a click means something.
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                hoverEnabled: true
                cursorShape: root.phase === "locked" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPressed: function (mouse) { root.beginHold(mouse.x, mouse.y) }
                onPositionChanged: function (mouse) { root.moveHold(mouse.x, mouse.y) }
                onReleased: root.cancelHold()
                onCanceled: root.cancelHold()
                onExited: root.cancelHold()
                onWheel: function (wheel) { wheel.accepted = true }
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: Model.hint(root.phase, root.holdProgress)
            color: root.holding ? root.foreground : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Cleaning for " + Model.formatClock(root.now - root.startedAt, false)
            color: root.muted
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
