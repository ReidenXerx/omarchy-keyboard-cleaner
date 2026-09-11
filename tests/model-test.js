#!/usr/bin/env node
// node tests/model-test.js — CleanerModel.js without a compositor.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const root = path.resolve(__dirname, "..")
const source = fs.readFileSync(path.join(root, "CleanerModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const box = {}
vm.runInNewContext(source + "\nthis.M = { DEFAULT_SECONDS, MIN_SECONDS, MAX_SECONDS, HOLD_MS, HOLD_SLOP, EVENT_MAX, clampSeconds, secondsFromPayload, parseEvent, formatClock, remainingFraction, holdFraction, movedTooFar, subtitle, hint }", box)
const M = box.M
const plain = v => JSON.parse(JSON.stringify(v))
const eq = (a, b, msg) => assert.deepStrictEqual(plain(a), plain(b), msg)

let passed = 0
const failures = []
function test(name, fn) {
  try { fn(); passed++ } catch (e) { failures.push(name + "\n    " + e.message) }
}

test("seconds come from the payload, clamped, with a default", () => {
  assert.strictEqual(M.secondsFromPayload('{"seconds":120}'), 120)
  assert.strictEqual(M.secondsFromPayload('{"seconds":"45"}'), 45)
  assert.strictEqual(M.secondsFromPayload('{"seconds":1}'), 15)
  assert.strictEqual(M.secondsFromPayload('{"seconds":99999}'), 600)
  assert.strictEqual(M.secondsFromPayload('{"seconds":59.6}'), 60)
  for (const bad of ["", "{}", "{nope", "[]", "null", '{"seconds":true}', '{"seconds":"1e3"}', '{"seconds":null}',
                     '{"seconds":NaN}', undefined, 42, '{"seconds":"' + "9".repeat(5000) + '"}'])
    assert.strictEqual(M.secondsFromPayload(bad), M.DEFAULT_SECONDS, String(bad).slice(0, 40))
})

test("guard events are parsed strictly", () => {
  eq(M.parseEvent('{"deadline":1789160000.5,"devices":10,"event":"locked","failed":1,"seconds":90}\n'),
     { event: "locked", devices: 10, failed: 1, deadlineMs: 1789160000500 })
  eq(M.parseEvent('{"event":"unlocked","ok":true,"reason":"unlock"}'), { event: "unlocked", ok: true, reason: "unlock" })
  eq(M.parseEvent('{"event":"unlocked","ok":"yes"}'), { event: "unlocked", ok: false, reason: "" })
  eq(M.parseEvent('{"event":"error","message":"Hyprland reported no keyboards to lock"}'),
     { event: "error", message: "Hyprland reported no keyboards to lock" })
  eq(M.parseEvent('{"event":"error"}'), { event: "error", message: "Something went wrong" })
  eq(M.parseEvent('{"event":"locked","deadline":5,"devices":-3,"failed":"x"}'), { event: "locked", devices: 0, failed: 0, deadlineMs: 5000 })
  for (const bad of ["", "   ", "nope", "[]", "null", '{"event":"locked"}', '{"event":"locked","deadline":"soon"}',
                     '{"event":"locked","deadline":0}', '{"event":"exploded"}', null, undefined,
                     '{"event":"error","message":"' + "x".repeat(M.EVENT_MAX) + '"}'])
    assert.strictEqual(M.parseEvent(bad), null, String(bad).slice(0, 40))
})

test("clock formatting", () => {
  assert.strictEqual(M.formatClock(90000, true), "1:30")
  assert.strictEqual(M.formatClock(89001, true), "1:30")
  assert.strictEqual(M.formatClock(89001, false), "1:29")
  assert.strictEqual(M.formatClock(5000, true), "0:05")
  assert.strictEqual(M.formatClock(-20, true), "0:00")
  assert.strictEqual(M.formatClock(600000, false), "10:00")
})

test("ring and hold fractions stay in 0..1", () => {
  assert.strictEqual(M.remainingFraction(0, 0, 1000), 1)
  assert.strictEqual(M.remainingFraction(500, 0, 1000), 0.5)
  assert.strictEqual(M.remainingFraction(2000, 0, 1000), 0)
  assert.strictEqual(M.remainingFraction(-5, 0, 1000), 1)
  assert.strictEqual(M.remainingFraction(0, 1000, 1000), 0)
  assert.strictEqual(M.holdFraction(0), 0)
  assert.strictEqual(M.holdFraction(M.HOLD_MS / 2), 0.5)
  assert.strictEqual(M.holdFraction(M.HOLD_MS * 2), 1)
  assert.strictEqual(M.holdFraction(-1), 0)
})

test("a hold survives a tremble but not a wipe", () => {
  assert.strictEqual(M.movedTooFar(100, 100, 110, 105), false)
  assert.strictEqual(M.movedTooFar(100, 100, 100 + M.HOLD_SLOP, 100), false)
  assert.strictEqual(M.movedTooFar(100, 100, 100 + M.HOLD_SLOP + 1, 100), true)
  assert.strictEqual(M.movedTooFar(100, 100, 80, 80), true)
})

test("texts follow the phase", () => {
  assert.strictEqual(M.subtitle("locked", 0, ""), "Every key is off. Wipe away.")
  assert.strictEqual(M.subtitle("locked", 1, ""), "Keyboard is off — 1 device could not be locked")
  assert.strictEqual(M.subtitle("locked", 2, ""), "Keyboard is off — 2 devices could not be locked")
  assert.strictEqual(M.subtitle("failed", 0, "boom"), "boom")
  assert.strictEqual(M.subtitle("failed", 0, ""), "Something went wrong")
  assert.strictEqual(M.subtitle("idle", 0, ""), "")
  assert.strictEqual(M.hint("locked", 0), "Hold a click on the ring for 3 seconds to unlock")
  assert.strictEqual(M.hint("locked", 0.1), "Keep holding… 3")
  assert.strictEqual(M.hint("locked", 0.99), "Keep holding… 1")
  assert.strictEqual(M.hint("unlocking", 0.5), "")
})

for (const f of failures) console.log("FAIL " + f)
console.log(passed + " passed, " + failures.length + " failed")
process.exit(failures.length ? 1 : 0)
