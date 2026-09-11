#!/usr/bin/python3
"""python3 tests/menu_install_test.py -- the vendored menu installer with this plugin's real
menu.jsonc, against a sandboxed menu file (never ~/.config/omarchy/extensions)."""
import importlib.machinery
import importlib.util
import os
import pathlib
import shutil
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "bin"))
import plugin_safety as safe  # noqa: E402


def load_installer():
    path = ROOT / "bin" / "keyboard-cleaner-menu-install"
    loader = importlib.machinery.SourceFileLoader("keyboard_cleaner_menu_install", str(path))
    spec = importlib.util.spec_from_loader("keyboard_cleaner_menu_install", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MenuInstall(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="kbclean-menu-test-", dir=safe.runtime_dir()))
        os.chmod(self.root, 0o700)
        # The file functions only work under $HOME or $XDG_RUNTIME_DIR, so the plugin's
        # snippet is copied into the sandbox rather than read from the checkout.
        self.plugin = self.root / "plugin"
        self.plugin.mkdir()
        shutil.copy(ROOT / "menu.jsonc", self.plugin / "menu.jsonc")
        self.m = load_installer()
        self.m.SNIPPET = self.plugin / "menu.jsonc"
        self.m.PLUGIN_DIR = self.plugin
        self.menu = self.root / "extensions" / "omarchy-menu.jsonc"
        self.m.EXTENSION = self.menu

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_is_the_template_for_this_plugin(self):
        self.assertEqual(self.m.PLUGIN_ID, "reidenxerx.keyboard-cleaner")

    def test_install_real_snippet_into_missing_file(self):
        self.assertEqual(self.m.install(), 0)
        text = self.menu.read_text()
        self.assertTrue(self.m.valid(text))
        self.assertIn('"setup.keyboard-cleaner.2"', text)
        self.assertIn(f"/usr/bin/python3 {self.plugin / 'bin'}/keyboard-cleaner restore", text)
        self.assertNotIn("@PLUGIN_BIN@", text)

    def test_reinstall_does_not_duplicate_and_remove_restores(self):
        self.menu.parent.mkdir(mode=0o700)
        original = '{\n  // mine\n  "mine": { "label": "Mine" },\n}\n'
        self.menu.write_text(original)
        self.m.install()
        self.m.install()
        self.assertEqual(self.menu.read_text().count('"setup.keyboard-cleaner"'), 1)
        self.m.remove()
        self.assertEqual(self.menu.read_text(), original)
        self.assertEqual([p.name for p in self.menu.parent.iterdir()], ["omarchy-menu.jsonc"])

    def test_symlinked_menu_file_is_refused(self):
        self.menu.parent.mkdir(mode=0o700)
        victim = self.root / "victim"
        victim.write_text("keep")
        self.menu.symlink_to(victim)
        self.assertEqual(self.m.main(["keyboard-cleaner-menu-install", "install"]), 1)
        self.assertEqual(victim.read_text(), "keep")


if __name__ == "__main__":
    unittest.main(verbosity=1)
