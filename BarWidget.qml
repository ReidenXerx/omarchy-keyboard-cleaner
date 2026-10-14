import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A keyboard in the bar: click it to start cleaning mode for the configured time.
BarWidget {
  id: root
  moduleName: "reidenxerx.keyboard-cleaner"

  readonly property int seconds: Math.max(15, Math.min(600, Math.round(Number(setting("seconds", 90))) || 90))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // md-spray_bottle (U+F0AE0), checked against the Nerd Font's own cmap. Not a keyboard
    // glyph: in a bar that reads as an input-method or layout indicator.
    text: "󰫠"
    foreground: root.bar ? root.bar.barForeground : Commons.Color.foreground
    tooltipText: "Clean keyboard — switches every key off for "
      + (root.seconds >= 60 && root.seconds % 60 === 0 ? (root.seconds / 60) + " min" : root.seconds + "s")
      + "\nHold a click on the ring to unlock early"

    // An argv list, not a shell line: the only program is Omarchy's own shell client.
    onPressed: function (b) {
      Quickshell.execDetached(["/usr/bin/omarchy-shell", "shell", "toggle", "reidenxerx.keyboard-cleaner",
                               JSON.stringify({ seconds: root.seconds })])
    }
  }
}
