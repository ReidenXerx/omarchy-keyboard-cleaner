import QtQuick
import "runtime" as Cleaner

// Standard Omarchy overlay entry point. The actual cleaning session belongs
// to the plugin-local runtime so a normally placed widget, a hosted widget,
// and shell IPC all address the same guard and surfaces.
Item {
  property var shell: null
  property var manifest: null
  readonly property bool opened: Cleaner.KeyboardCleanerRuntime.opened

  function open(payloadJson) {
    Cleaner.KeyboardCleanerRuntime.open(payloadJson)
  }

  function close() {
    Cleaner.KeyboardCleanerRuntime.close()
  }
}
