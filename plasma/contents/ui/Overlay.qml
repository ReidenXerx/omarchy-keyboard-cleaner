import QtQuick
import QtQml
import QtQuick.Window
import org.kde.kirigami as Kirigami
import "../code/CleanerModel.js" as Model

// The card over every screen while the keys are off: the time left on a ring, and the ring itself as the only way
// out early -- a click held still on it for three seconds. Moving the pointer cancels the hold, so a cloth
// sweeping across the touchpad cannot unlock by accident.
Item {
  id: overlay

  required property var cleaner

  property double now: Date.now()
  property bool holding: false
  property double holdStartedAt: 0
  property real holdX: 0
  property real holdY: 0
  readonly property real holdProgress: overlay.holding ? Model.holdFraction(overlay.now - overlay.holdStartedAt) : 0

  Timer {
    interval: overlay.holding ? 50 : 250
    repeat: true
    running: true
    onTriggered: {
      overlay.now = Date.now()
      if (overlay.holding && overlay.holdProgress >= 1) {
        overlay.holding = false
        overlay.cleaner.unlock()
      }
    }
  }

  // One window per screen; an Instantiator, since a Repeater can only make Items.
  Instantiator {
    model: Qt.application.screens
    delegate: Window {
      id: surface
      required property var modelData
      screen: modelData
      visible: true
      visibility: Window.FullScreen
      flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
      color: Qt.rgba(0.03, 0.04, 0.06, 0.92)
      title: "Keyboard cleaner"

      // Clicks anywhere land here and do nothing.
      MouseArea { anchors.fill: parent }

      Column {
        anchors.centerIn: parent
        spacing: Kirigami.Units.gridUnit

        Item {
          id: ring
          anchors.horizontalCenter: parent.horizontalCenter
          width: Kirigami.Units.gridUnit * 14
          height: width

          Canvas {
            id: dial
            anchors.fill: parent
            readonly property real remaining: Model.remainingFraction(overlay.now, overlay.cleaner.startedAt, overlay.cleaner.deadlineAt)
            readonly property real hold: overlay.holdProgress
            onRemainingChanged: requestPaint()
            onHoldChanged: requestPaint()
            onPaint: {
              var c = getContext("2d")
              c.reset()
              var cx = width / 2, cy = height / 2, r = width / 2 - 14
              c.lineWidth = 12
              c.lineCap = "round"
              c.strokeStyle = Qt.rgba(1, 1, 1, 0.12)
              c.beginPath(); c.arc(cx, cy, r, 0, 2 * Math.PI); c.stroke()
              c.strokeStyle = overlay.cleaner.phase === "failed" ? "#E5484D" : Kirigami.Theme.highlightColor
              c.beginPath(); c.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * dial.remaining); c.stroke()
              if (dial.hold > 0) {
                c.strokeStyle = "#FFFFFF"
                c.lineWidth = 5
                c.beginPath(); c.arc(cx, cy, r - 18, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * dial.hold); c.stroke()
              }
            }
          }

          Column {
            anchors.centerIn: parent
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              color: "white"
              font.pixelSize: Kirigami.Units.gridUnit * 3
              font.weight: Font.Light
              text: overlay.cleaner.phase === "failed" ? "—" : Model.formatClock(overlay.cleaner.deadlineAt - overlay.now, true)
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              color: Qt.rgba(1, 1, 1, 0.6)
              text: "cleaning for " + Model.formatClock(overlay.now - overlay.cleaner.startedAt, false)
            }
          }

          MouseArea {
            anchors.fill: parent
            enabled: overlay.cleaner.phase === "locked"
            cursorShape: Qt.PointingHandCursor
            onPressed: function (mouse) {
              overlay.holding = true
              overlay.holdStartedAt = Date.now()
              overlay.holdX = mouse.x
              overlay.holdY = mouse.y
            }
            onPositionChanged: function (mouse) {
              if (overlay.holding && Model.movedTooFar(overlay.holdX, overlay.holdY, mouse.x, mouse.y)) overlay.holding = false
            }
            onReleased: overlay.holding = false
            onCanceled: overlay.holding = false
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          color: "white"
          font.pixelSize: Kirigami.Units.gridUnit * 1.3
          text: Model.subtitle(overlay.cleaner.phase, 0, overlay.cleaner.message)
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          color: Qt.rgba(1, 1, 1, 0.6)
          text: Model.hint(overlay.cleaner.phase, overlay.holdProgress)
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: overlay.cleaner.phase === "locked" && overlay.cleaner.message !== ""
          textFormat: Text.PlainText
          color: "#FFB4AB"
          text: overlay.cleaner.message
        }
      }
    }
  }
}
