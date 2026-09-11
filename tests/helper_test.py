#!/usr/bin/python3
"""python3 tests/helper_test.py -- bin/keyboard-cleaner against a simulated Hyprland and a
sandboxed lock record. Nothing here switches a real device off."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
BIN = ROOT / "bin"
sys.dont_write_bytecode = True
sys.path.insert(0, str(BIN))
import plugin_safety as safe  # noqa: E402

SAFETY_SHA256 = "bf8ffb9ff874caa1958526c1d0a9bd239a55842c979d41cd916675075cf8ec87"
CALL = re.compile(r'hl\.device\(\{ name = "((?:[^"\\]|\\[0-9]{3})*)", enabled = (true|false) \}\)')


def load_helper():
    loader = importlib.machinery.SourceFileLoader("keyboard_cleaner", str(BIN / "keyboard-cleaner"))
    spec = importlib.util.spec_from_loader("keyboard_cleaner", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def result(stdout=b"", returncode=0, timed_out=False, truncated=False):
    return safe.Result(returncode, stdout, b"", timed_out, truncated)


def lua_unquote(literal):
    raw = bytearray()
    i = 0
    while i < len(literal):
        if literal[i] == "\\":
            raw.append(int(literal[i + 1:i + 4]))
            i += 4
        else:
            raw.extend(literal[i].encode())
            i += 1
    return raw.decode("utf-8")


class FakeProc:
    def __init__(self, argv):
        self.argv, self.pid = argv, None

    def poll(self):
        return 0


class FakeHyprland:
    """`hyprctl -j devices` and `hyprctl eval` over an in-memory device table."""

    def __init__(self, names):
        self.names = list(names)
        self.enabled = {n: True for n in names}
        self.down = False
        self.fail_evals = 0
        self.reject = set()       # names whose own eval fails
        self.calls = []
        self.spawned = []

    def run(self, argv, **kw):
        self.calls.append((list(argv), kw))
        if self.down:
            return result(returncode=1)
        if argv == ["hyprctl", "-j", "devices"]:
            doc = {"mice": [{"name": "touchpad"}], "keyboards": [{"name": n, "main": i == 0} for i, n in enumerate(self.names)]}
            return result(json.dumps(doc).encode())
        if argv[:2] == ["hyprctl", "eval"] and len(argv) == 3:
            if self.fail_evals:
                self.fail_evals -= 1
                return result(b"error: something\n")
            calls = [(lua_unquote(n), flag == "true") for n, flag in CALL.findall(argv[2])]
            if any(n in self.reject for n, _ in calls):
                return result(b"error: no such device\n")
            for name, flag in calls:
                self.enabled[name] = flag
            return result(b"ok\n")
        return result(returncode=1)

    def spawn(self, argv, **kw):
        self.spawned.append((list(argv), kw))
        return FakeProc(argv)

    def off(self):
        return sorted(n for n, on in self.enabled.items() if not on)


class Helper(unittest.TestCase):
    NAMES = ["at-translated-set-2-keyboard", "power-button", "dell-wmi-hotkeys", "logitech-usb-receiver"]

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="kbclean-test-", dir=safe.runtime_dir()))
        os.chmod(self.root, 0o700)
        self.addCleanup(shutil.rmtree, self.root, True)
        self.m = load_helper()
        self.state = self.root / "run" / "lock.json"
        self.hypr = FakeHyprland(self.NAMES)
        patches = [mock.patch.object(self.m, "STATE", self.state),
                   mock.patch.object(self.m, "POLL", 0.02),
                   mock.patch.object(self.m, "RESCAN_EVERY", 0.05),
                   mock.patch.object(self.m.safe, "run", self.hypr.run),
                   mock.patch.object(self.m.safe, "spawn", self.hypr.spawn),
                   mock.patch.object(self.m.time, "sleep", lambda s: None)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.events = []

    def start_lock(self, seconds=60):
        read_fd, write_fd = os.pipe()
        self.addCleanup(lambda: [os.close(fd) for fd in (read_fd, write_fd) if self._open(fd)])
        box = {}
        thread = threading.Thread(target=lambda: box.setdefault("code", self.m.lock(seconds, read_fd, self.events.append)))
        thread.start()
        self.addCleanup(thread.join, 5)
        return thread, write_fd, box

    @staticmethod
    def _open(fd):
        try:
            os.fstat(fd)
            return True
        except OSError:
            return False

    def wait_for(self, predicate, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return True
            threading.Event().wait(0.01)
        return False

    def locked(self):
        return self.wait_for(lambda: any(e["event"] == "locked" for e in self.events))

    def saved(self):
        return json.loads(self.state.read_text())


class Lua(Helper):
    def test_any_name_becomes_a_literal_that_cannot_break_out(self):
        for name in ['plain-name', 'quote"} ) os.execute("id") --', "back\\slash", "new\nline",
                     "ünïcödé keyboard", "\x00nul", "]] --[["]:
            literal = self.m.lua_string(name)
            self.assertTrue(literal.startswith('"') and literal.endswith('"'))
            body = literal[1:-1]
            self.assertIsNone(re.search(r'["\n\x00]', body), name)
            self.assertIsNone(re.search(r"\\(?![0-9]{3})", body), name)
            self.assertEqual(lua_unquote(body), name)

    def test_device_call_shape(self):
        self.assertEqual(self.m.device_call("power-button", False),
                         'hl.device({ name = "power-button", enabled = false })')


class Devices(Helper):
    def test_keyboards_are_listed_once_and_bounded(self):
        self.hypr.names = ["a", "b", "a", "c"] + [f"kb{i}" for i in range(300)]
        names = self.m.keyboards()
        self.assertEqual(names[:3], ["a", "b", "c"])
        self.assertEqual(len(names), self.m.DEVICES_MAX)

    def test_unusable_answers_are_none(self):
        for answer in (result(returncode=1), result(b"not json"), result(b"[]"), result(b'{"keyboards": 5}'),
                       result(b'{"keyboards": []}', truncated=True)):
            with mock.patch.object(self.m.safe, "run", lambda argv, **kw: answer):
                self.assertIn(self.m.keyboards(), (None, []), answer.stdout)
        with mock.patch.object(self.m.safe, "run", lambda argv, **kw: result(json.dumps(
                {"keyboards": [{"name": 5}, {"name": ""}, {"name": "x\x07"}, "junk", {"name": "ok"}]}).encode())):
            self.assertEqual(self.m.keyboards(), ["ok"])

    def test_one_bad_name_does_not_stop_the_rest(self):
        self.hypr.reject = {"power-button"}
        failed = self.m.set_devices(self.NAMES, False)
        self.assertEqual(failed, ["power-button"])
        self.assertEqual(self.hypr.off(), sorted(n for n in self.NAMES if n != "power-button"))


class Lock(Helper):
    def test_lock_records_first_then_switches_everything_off_and_back_on(self):
        order = []
        real_save = self.m.save_state
        with mock.patch.object(self.m, "save_state", lambda s: (order.append(("save", self.hypr.off())), real_save(s))):
            thread, write_fd, box = self.start_lock(60)
            self.assertTrue(self.locked())
        self.assertEqual(order[0], ("save", []))                   # recorded while nothing was off yet
        self.assertEqual(self.hypr.off(), sorted(self.NAMES))
        state = self.saved()
        self.assertEqual(sorted(state["devices"]), sorted(self.NAMES))
        self.assertRegex(state["id"], r"^[0-9a-f]{16}$")
        self.assertEqual(oct(os.stat(self.state).st_mode & 0o777), "0o600")

        locked = next(e for e in self.events if e["event"] == "locked")
        self.assertEqual((locked["devices"], locked["failed"], locked["seconds"]), (4, 0, 60))
        self.assertAlmostEqual(locked["deadline"], time.time() + 60, delta=3)

        watchdog, inhibitor = self.hypr.spawned
        self.assertEqual(watchdog[0][:4], ["/usr/bin/python3", str(BIN / "keyboard-cleaner"), "restore-at", state["id"]])
        self.assertGreater(watchdog[1]["timeout"], 60 + self.m.WATCHDOG_GRACE)
        self.assertEqual(inhibitor[0][0], "systemd-inhibit")
        self.assertIn("--what=handle-power-key:handle-suspend-key:handle-hibernate-key", inhibitor[0])

        os.write(write_fd, b"unlock\n")
        thread.join(5)
        self.assertEqual(box["code"], 0)
        self.assertEqual(self.hypr.off(), [])
        self.assertFalse(self.state.exists())
        self.assertEqual(self.events[-1], {"event": "unlocked", "reason": "unlock", "ok": True})

    def test_closed_stdin_means_the_shell_is_gone(self):
        thread, write_fd, box = self.start_lock()
        self.assertTrue(self.locked())
        os.close(write_fd)
        thread.join(5)
        self.assertEqual((box["code"], self.events[-1]["reason"], self.hypr.off()), (0, "parent gone", []))

    def test_the_timer_ends_it(self):
        thread, write_fd, box = self.start_lock(seconds=0.3)
        thread.join(5)
        self.assertEqual((box["code"], self.events[-1]["reason"], self.hypr.off()), (0, "timer", []))

    def test_a_signal_ends_it(self):
        thread, write_fd, box = self.start_lock()
        self.assertTrue(self.locked())
        self.m.on_signal(15, None)
        thread.join(5)
        self.assertEqual((box["code"], self.events[-1]["reason"], self.hypr.off()), (0, "sigterm", []))

    def test_a_config_reload_mid_lock_is_undone_and_hotplugged_keyboards_are_locked_too(self):
        thread, write_fd, box = self.start_lock()
        self.assertTrue(self.locked())
        for name in self.NAMES:                 # what a Hyprland config reload does
            self.hypr.enabled[name] = True
        self.hypr.names.append("usb-keyboard-plugged-in")
        self.hypr.enabled["usb-keyboard-plugged-in"] = True
        self.assertTrue(self.wait_for(lambda: len(self.hypr.off()) == len(self.NAMES) + 1))
        self.assertIn("usb-keyboard-plugged-in", self.saved()["devices"])
        os.write(write_fd, b"unlock\n")
        thread.join(5)
        self.assertEqual(self.hypr.off(), [])

    def test_no_keyboards_or_no_hyprland_locks_nothing(self):
        self.hypr.names = []
        self.assertEqual(self.m.lock(60, 0, self.events.append), 1)
        self.hypr.down = True
        self.assertEqual(self.m.lock(60, 0, self.events.append), 1)
        self.assertEqual([e["event"] for e in self.events], ["error", "error"])
        self.assertFalse(self.state.exists())
        self.assertEqual(self.hypr.spawned, [])

    def test_no_watchdog_means_no_lock(self):
        def no_spawn(argv, **kw):
            raise safe.UnsafeError("timeout is not installed in /usr/bin")
        with mock.patch.object(self.m.safe, "spawn", no_spawn):
            self.assertEqual(self.m.lock(60, 0, self.events.append), 1)
        self.assertEqual(self.hypr.off(), [])
        self.assertFalse(self.state.exists())
        self.assertEqual(self.events[-1]["message"], "Could not start the unlock watchdog")

    def test_a_lock_left_by_a_crashed_guard_is_given_back_before_a_new_one(self):
        self.hypr.enabled["power-button"] = False
        self.state.parent.mkdir(mode=0o700)
        self.state.write_text(json.dumps({"id": "0" * 16, "devices": ["power-button"], "deadline": 1.0}))
        thread, write_fd, box = self.start_lock()
        self.assertTrue(self.locked())
        self.assertNotEqual(self.saved()["id"], "0" * 16)
        os.write(write_fd, b"unlock\n")
        thread.join(5)
        self.assertEqual(self.hypr.off(), [])


class Restore(Helper):
    def write_state(self, text):
        self.state.parent.mkdir(mode=0o700, exist_ok=True)
        self.state.write_text(text)

    def test_nothing_locked_runs_no_tools(self):
        self.assertEqual(self.m.restore(), 0)
        self.assertEqual(self.hypr.calls, [])

    def test_switches_back_on_exactly_what_was_recorded(self):
        for n in ("power-button", "dell-wmi-hotkeys"):
            self.hypr.enabled[n] = False
        self.write_state(json.dumps({"id": "a" * 16, "devices": ["power-button", "dell-wmi-hotkeys"], "deadline": 5.0}))
        self.assertEqual(self.m.restore(), 0)
        self.assertEqual(self.hypr.off(), [])
        self.assertFalse(self.state.exists())

    def test_an_untrustworthy_record_switches_on_every_keyboard(self):
        for text in ("{nope", "[]", '{"id": "zz", "devices": [], "deadline": 1}', '{"pad": "' + "x" * 70000 + '"}'):
            for n in self.NAMES:
                self.hypr.enabled[n] = False
            self.write_state(text)
            self.assertEqual(self.m.restore(), 0, text[:40])
            self.assertEqual(self.hypr.off(), [], text[:40])
            self.assertFalse(self.state.exists())

    def test_a_symlinked_record_still_gives_the_keyboards_back_but_is_not_touched(self):
        for n in self.NAMES:
            self.hypr.enabled[n] = False
        victim = self.root / "victim.json"
        victim.write_text('{"keep": true}')
        self.state.parent.mkdir(mode=0o700)
        self.state.symlink_to(victim)
        self.assertEqual(self.m.restore(), 1)
        self.assertEqual(self.hypr.off(), [])
        self.assertTrue(self.state.is_symlink())
        self.assertEqual(victim.read_text(), '{"keep": true}')

    def test_a_failed_restore_keeps_the_record_for_the_next_try(self):
        self.hypr.enabled["power-button"] = False
        self.write_state(json.dumps({"id": "b" * 16, "devices": ["power-button"], "deadline": 5.0}))
        self.hypr.down = True
        self.assertEqual(self.m.restore(), 1)
        self.assertTrue(self.state.exists())
        self.hypr.down = False
        self.hypr.fail_evals = 3                 # the next attempts inside one restore succeed
        self.assertEqual(self.m.restore(), 0)
        self.assertEqual(self.hypr.off(), [])

    def test_untrustworthy_record_with_hyprland_unreachable_is_kept(self):
        self.write_state("{nope")
        self.hypr.down = True
        self.assertEqual(self.m.restore(), 1)
        self.assertTrue(self.state.exists())


class Watchdog(Helper):
    def test_stands_down_when_the_lock_ended_or_a_newer_one_exists(self):
        self.assertEqual(self.m.restore_at("c" * 16, time.time() - 100), 0)
        self.state.parent.mkdir(mode=0o700)
        self.state.write_text(json.dumps({"id": "d" * 16, "devices": ["power-button"], "deadline": 1.0}))
        self.hypr.enabled["power-button"] = False
        self.assertEqual(self.m.restore_at("c" * 16, time.time() - 100), 0)
        self.assertEqual(self.hypr.off(), ["power-button"])

    def test_restores_its_own_lock_after_the_deadline(self):
        self.state.parent.mkdir(mode=0o700)
        self.state.write_text(json.dumps({"id": "e" * 16, "devices": self.NAMES, "deadline": 1.0}))
        for n in self.NAMES:
            self.hypr.enabled[n] = False
        self.assertEqual(self.m.restore_at("e" * 16, time.time() - self.m.WATCHDOG_GRACE - 1), 0)
        self.assertEqual(self.hypr.off(), [])
        self.assertFalse(self.state.exists())

    def test_waits_until_the_deadline(self):
        self.state.parent.mkdir(mode=0o700)
        self.state.write_text(json.dumps({"id": "f" * 16, "devices": ["power-button"], "deadline": 1.0}))
        slept = []
        clock = [1000.0]
        with mock.patch.object(self.m.time, "sleep", lambda s: (slept.append(s), clock.__setitem__(0, clock[0] + s))), \
                mock.patch.object(self.m.time, "time", lambda: clock[0]):
            self.assertEqual(self.m.restore_at("f" * 16, 1003.0), 0)
        self.assertAlmostEqual(sum(slept), 3 + self.m.WATCHDOG_GRACE, delta=0.01)


class Cli(Helper):
    def cli(self, *args):
        return self.m.main(["keyboard-cleaner", *args])

    def test_arguments_are_validated_before_anything_runs(self):
        for args in (("lock",), ("lock", "5"), ("lock", "601"), ("lock", "abc"), ("lock", "60", "x"),
                     ("restore", "now"), ("restore-at", "short", "1.0"), ("restore-at", "a" * 16, "soon"),
                     ("restore-at", "a" * 16), ("frobnicate",), ()):
            self.assertEqual(self.cli(*args), 2, args)
        self.assertEqual(self.hypr.calls, [])
        self.assertEqual(self.hypr.spawned, [])


class Static(unittest.TestCase):
    """Properties a reviewer checks by reading; kept true by test rather than by memory."""

    def test_vendored_safety_library_is_the_reviewed_copy(self):
        self.assertEqual(hashlib.sha256((BIN / "plugin_safety.py").read_bytes()).hexdigest(), SAFETY_SHA256)

    def test_python_entry_points_use_the_system_interpreter(self):
        for name in ("keyboard-cleaner", "keyboard-cleaner-menu-install"):
            self.assertTrue((BIN / name).read_text().startswith("#!/usr/bin/python3\n"), name)

    def test_helper_has_no_direct_process_or_file_access(self):
        src = (BIN / "keyboard-cleaner").read_text()
        for pattern in (r"\bsubprocess\b", r"\bos\.system\b", r"\bos\.popen\b", r"shell\s*=", r"\bopen\(",
                        r"\.read_text\(", r"\.write_text\(", r"\bexec\(", r"\beval\("):
            self.assertIsNone(re.search(pattern, src), pattern)

    def test_overlay_runs_only_the_helper_and_keeps_the_guards_stdin_open(self):
        qml = (ROOT / "KeyboardCleaner.qml").read_text()
        self.assertIn("stdinEnabled: true", qml)
        # Touchpad gestures are Hyprland's own; only a shortcuts inhibitor pauses them.
        self.assertRegex(qml, r"ShortcutInhibitor \{\s*enabled: root\.opened && surface\.primary\s*window: surface")
        self.assertNotIn("FileView", qml)
        runs = re.findall(r"(?:command =|execDetached\()\s*([^\n]*)", qml)
        self.assertGreaterEqual(len(runs), 4)
        for line in runs:
            self.assertTrue(line.startswith("[root.python, root.helper,"), line)
        self.assertIn('readonly property string python: "/usr/bin/python3"', qml)

    def test_bar_widget_starts_the_overlay_with_an_argv_list(self):
        qml = (ROOT / "BarWidget.qml").read_text()
        self.assertIn('Quickshell.execDetached(["/usr/bin/omarchy-shell", "shell", "toggle", "reidenxerx.keyboard-cleaner",', qml)
        self.assertNotIn("bar.run", qml)

    def test_menu_actions_are_the_overlay_or_the_helper(self):
        text = (ROOT / "menu.jsonc").read_text()
        actions = re.findall(r'"action":\s*"((?:[^"\\]|\\.)*)"', text)
        self.assertEqual(len(actions), 4)
        allowed = re.compile(r"omarchy-shell shell toggle reidenxerx\.keyboard-cleaner '\{\\\"seconds\\\":[0-9]+\}'"
                             r"|/usr/bin/python3 @PLUGIN_BIN@/keyboard-cleaner restore")
        for action in actions:
            self.assertIsNotNone(allowed.fullmatch(action), action)

    def test_manifest(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["id"], "reidenxerx.keyboard-cleaner")
        self.assertEqual(sorted(manifest["kinds"]), ["bar-widget", "overlay"])
        for entry in manifest["entryPoints"].values():
            self.assertTrue((ROOT / entry).is_file(), entry)


if __name__ == "__main__":
    unittest.main(verbosity=1)
