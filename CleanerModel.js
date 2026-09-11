.pragma library

// Pure display logic for cleaning mode, kept out of the QML so it can be tested without a
// compositor (node tests/model-test.js).

var DEFAULT_SECONDS = 90
var MIN_SECONDS = 15
var MAX_SECONDS = 600
// Three seconds of a click held still on the ring. Long enough that a cloth pressing the
// touchpad does not do it, short enough not to feel stuck.
var HOLD_MS = 3000
// Movement that cancels a hold, in logical pixels: wiping a touchpad moves the pointer.
var HOLD_SLOP = 24
// The guard ends the lock at its deadline; past this the overlay asks it to stop.
var OVERDUE_MS = 15000
var PAYLOAD_MAX = 4096
var EVENT_MAX = 1024

function clampSeconds(value, fallback) {
  var n = typeof value === "string" && /^\s*[0-9]{1,4}\s*$/.test(value) ? parseInt(value, 10)
        : (typeof value === "number" && isFinite(value) ? Math.round(value) : NaN)
  if (!isFinite(n)) return fallback
  return Math.min(MAX_SECONDS, Math.max(MIN_SECONDS, n))
}

// `{"seconds": 120}` from the bar widget or a menu entry; anything else is the default.
function secondsFromPayload(json) {
  if (typeof json !== "string" || json.length > PAYLOAD_MAX) return DEFAULT_SECONDS
  var payload = null
  try { payload = JSON.parse(json) } catch (e) { return DEFAULT_SECONDS }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return DEFAULT_SECONDS
  return clampSeconds(payload.seconds, DEFAULT_SECONDS)
}

function count(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 ? Math.floor(value) : 0
}

// One line of the guard's output. null for anything that is not an event it sends.
function parseEvent(line) {
  var s = String(line === undefined || line === null ? "" : line).trim()
  if (!s || s.length > EVENT_MAX) return null
  var e = null
  try { e = JSON.parse(s) } catch (err) { return null }
  if (!e || typeof e !== "object" || Array.isArray(e)) return null
  if (e.event === "locked") {
    if (typeof e.deadline !== "number" || !isFinite(e.deadline) || e.deadline <= 0) return null
    return { event: "locked", devices: count(e.devices), failed: count(e.failed), deadlineMs: e.deadline * 1000 }
  }
  if (e.event === "unlocked")
    return { event: "unlocked", ok: e.ok === true, reason: typeof e.reason === "string" ? e.reason.slice(0, 64) : "" }
  if (e.event === "error")
    return { event: "error", message: typeof e.message === "string" && e.message ? e.message.slice(0, 200) : "Something went wrong" }
  return null
}

// "1:05". Counting down, a part-second still shows as a second: 0:00 means it is over.
function formatClock(ms, roundUp) {
  var total = Math.max(0, roundUp ? Math.ceil(ms / 1000) : Math.floor(ms / 1000))
  var m = Math.floor(total / 60)
  var s = total % 60
  return m + ":" + (s < 10 ? "0" : "") + s
}

function remainingFraction(nowMs, startMs, deadlineMs) {
  var span = deadlineMs - startMs
  if (!(span > 0)) return 0
  return Math.max(0, Math.min(1, (deadlineMs - nowMs) / span))
}

function holdFraction(heldMs) {
  return Math.max(0, Math.min(1, heldMs / HOLD_MS))
}

function movedTooFar(originX, originY, x, y) {
  var dx = x - originX
  var dy = y - originY
  return dx * dx + dy * dy > HOLD_SLOP * HOLD_SLOP
}

function subtitle(phase, failed, message) {
  if (phase === "locking") return "Switching every key off…"
  if (phase === "locked")
    return failed > 0 ? "Keyboard is off — " + failed + (failed === 1 ? " device" : " devices") + " could not be locked"
                      : "Every key is off. Wipe away."
  if (phase === "unlocking") return "Giving the keyboard back…"
  if (phase === "failed") return message || "Something went wrong"
  return ""
}

function hint(phase, holdProgress) {
  if (phase !== "locked") return ""
  if (holdProgress > 0) {
    var left = Math.max(1, Math.ceil((1 - holdProgress) * HOLD_MS / 1000))
    return "Keep holding… " + left
  }
  return "Hold a click on the ring for 3 seconds to unlock"
}
