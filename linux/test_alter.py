#!/usr/bin/env python3
"""Tests for Alter for Linux. Run: python3 linux/test_alter.py
Everything happens in a throwaway home folder. Set ALTER_TEST_BROWSER to a Chromium/Chrome binary
(and have a display, e.g. under xvfb-run) to also run two real browser copies side by side."""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ALTER = os.path.join(HERE, "alter")


def load_module():
    loader = importlib.machinery.SourceFileLoader("alter_cli", ALTER)
    spec = importlib.util.spec_from_loader("alter_cli", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class AlterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="alter-test-")
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.home)
        os.makedirs(self.bin)
        self.env = dict(os.environ, HOME=self.home, XDG_DATA_HOME=os.path.join(self.home, ".local", "share"),
                        PATH=self.bin + os.pathsep + os.environ.get("PATH", ""))
        self.env.pop("XDG_DATA_DIRS", None)
        self.share = self.env["XDG_DATA_HOME"]
        # A fake app that saves settings the XDG way and the ~/.dotfile way, then stays open.
        self.app = os.path.join(self.bin, "notes-app")
        with open(self.app, "w") as f:
            f.write('#!/bin/sh\ncfg="${XDG_CONFIG_HOME:-$HOME/.config}/notes-app"; mkdir -p "$cfg"\n'
                    'echo "account=$1" > "$cfg/settings"; echo "account=$1" > "$HOME/.notes-app-rc"\nsleep 30\n')
        os.chmod(self.app, 0o755)

    def tearDown(self):
        for name in ("Work", "Home", "Chrome Work", "Chrome Home"):
            self.run_alter("stop", name, "--force", check=False)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_alter(self, *args, check=True):
        r = subprocess.run([sys.executable, ALTER, *args], env=self.env, capture_output=True, text=True)
        if check and r.returncode != 0:
            self.fail(f"alter {' '.join(args)} failed:\n{r.stdout}\n{r.stderr}")
        return r

    def cfg(self, cid):
        with open(os.path.join(self.share, "alter", "copies", cid, "config.json")) as f:
            return json.load(f)

    def launcher(self, cid):
        with open(os.path.join(self.share, "alter", "copies", cid, "launch")) as f:
            return f.read()

    # ---------------------------------------------------------------------------------------
    def test_monogram_matches_windows_rule(self):
        m = load_module()
        self.assertEqual(m.monogram("Claude 2"), "CL2")
        self.assertEqual(m.monogram("Slack Client"), "SC")
        self.assertEqual(m.monogram("Discord"), "DIS")
        self.assertEqual(m.monogram(""), "ALT")

    def test_verdicts(self):
        m = load_module()
        v = lambda kind, target, base=None: m.verdict({"kind": kind, "target": target, "base": base or os.path.basename(target)})[0]
        self.assertEqual(v("exe", "/usr/bin/google-chrome"), "works")
        self.assertEqual(v("exe", "/usr/bin/firefox"), "works")
        self.assertEqual(v("exe", "/usr/bin/discord"), "works")
        self.assertEqual(v("exe", "/usr/bin/spotify"), "no")
        self.assertEqual(v("exe", "/usr/games/steam"), "no")
        self.assertEqual(v("exe", self.app), "maybe")
        self.assertEqual(v("snap", "/snap/bin/firefox"), "no")
        self.assertEqual(v("flatpak", "com.discordapp.Discord"), "works")
        self.assertEqual(v("flatpak", "com.spotify.Client"), "no")
        self.assertEqual(v("flatpak", "org.example.Unknown"), "maybe")

    def test_apps_lists_verdicts_and_new_warns(self):
        apps = os.path.join(self.share, "applications")
        os.makedirs(apps, exist_ok=True)
        spotify = os.path.join(self.bin, "spotify")
        shutil.copy(self.app, spotify)
        with open(os.path.join(apps, "spotify.desktop"), "w") as f:
            f.write("[Desktop Entry]\nType=Application\nName=Spotify\nExec=spotify %U\n")
        with open(os.path.join(apps, "notes.desktop"), "w") as f:
            f.write(f"[Desktop Entry]\nType=Application\nName=Notes\nExec={self.app}\n")
        self.env["XDG_DATA_DIRS"] = os.path.join(self.tmp, "none")
        out = self.run_alter("apps").stdout
        self.assertRegex(out, r"Won't work\s+Spotify")
        self.assertRegex(out, r"Might work\s+Notes")
        self.assertLess(out.index("Might work"), out.index("Won't work"), "Works / Might work / Won't work order")
        only = self.run_alter("apps", "--only", "no").stdout
        self.assertIn("Spotify", only)
        self.assertNotIn("Notes", only)
        by_name = self.run_alter("apps", "--sort", "name-desc").stdout
        self.assertLess(by_name.index("Spotify"), by_name.index("Notes"), "Z-A puts Spotify before Notes")
        r = self.run_alter("new", "Spotify 2", "--app", "spotify")      # warns, but still makes the copy
        self.assertIn("probably won't work", r.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.share, "alter", "copies", "spotify-2", "launch")))

    def test_bad_names_are_refused(self):
        r = self.run_alter("new", "bad/name", "--app", self.app, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("1-40 characters", r.stderr)

    def test_redirect_mode_keeps_xdg_data_apart(self):
        self.run_alter("new", "Work", "--app", self.app)
        self.assertEqual(self.cfg("work")["mode"], "redirect")
        self.run_alter("launch", "Work", "work@example.com")
        time.sleep(1)
        settings = os.path.join(self.share, "alter", "copies", "work", "data", "config", "notes-app", "settings")
        self.assertTrue(os.path.exists(settings))
        with open(settings) as f:
            self.assertEqual(f.read().strip(), "account=work@example.com")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "notes-app")))
        self.assertIn("running", self.run_alter("list").stdout)

    def test_home_mode_also_catches_dotfiles(self):
        self.run_alter("new", "Home", "--app", self.app, "--mode", "home")
        self.run_alter("launch", "Home", "home@example.com")
        time.sleep(1)
        self.assertTrue(os.path.exists(os.path.join(self.share, "alter", "copies", "home", "data", "home", ".notes-app-rc")))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".notes-app-rc")))

    def test_stop_and_delete(self):
        self.run_alter("new", "Work", "--app", self.app)
        self.run_alter("launch", "Work")
        time.sleep(0.5)
        r = self.run_alter("delete", "Work", "--yes", check=False)
        self.assertNotEqual(r.returncode, 0, "deleting a running copy must be refused")
        self.run_alter("stop", "Work")
        self.assertIn("stopped", self.run_alter("list").stdout)
        self.run_alter("delete", "Work", "--yes")
        self.assertFalse(os.path.exists(os.path.join(self.share, "alter", "copies", "work")))
        self.assertFalse(os.path.exists(os.path.join(self.share, "applications", "alter-work.desktop")))

    def test_chromium_mode_launcher_and_menu_entry(self):
        chrome = os.path.join(self.bin, "google-chrome")
        shutil.copy(self.app, chrome)
        self.run_alter("new", "Chrome Work", "--app", chrome)
        c = self.cfg("chrome-work")
        self.assertEqual(c["mode"], "chromium")
        text = self.launcher("chrome-work")
        self.assertIn("--user-data-dir=", text)
        self.assertIn("--class=alter-chrome-work", text)
        self.assertIn("export ALTER_COPY=chrome-work", text)
        with open(os.path.join(self.share, "applications", "alter-chrome-work.desktop")) as f:
            desktop = f.read()
        self.assertIn("StartupWMClass=alter-chrome-work", desktop)
        self.assertIn("Name=Chrome Work", desktop)
        if shutil.which("desktop-file-validate"):
            subprocess.run(["desktop-file-validate", os.path.join(self.share, "applications", "alter-chrome-work.desktop")], check=True)

    def test_flatpak_launcher(self):
        # No Flatpak needed: build the config by hand and check the generated command.
        m = load_module()
        m.ROOT = os.path.join(self.share, "alter", "copies")
        m.HOME = self.home
        cfg = {"id": "discord-alt", "name": "Discord Alt", "kind": "flatpak", "target": "com.discordapp.Discord",
               "base": "com.discordapp.Discord", "mode": "chromium", "args": [], "env": {}}
        os.makedirs(m.copy_dir("discord-alt"))
        with open(m.write_launcher(cfg)) as f:
            text = f.read()
        self.assertIn("flatpak run --env=ALTER_COPY=discord-alt com.discordapp.Discord --multi-instance", text)
        self.assertIn(os.path.join(self.home, ".var", "app", "com.discordapp.Discord", "alter", "discord-alt", "profile"), text)

    @unittest.skipUnless(os.environ.get("ALTER_TEST_BROWSER") and os.environ.get("DISPLAY"),
                         "set ALTER_TEST_BROWSER and DISPLAY to run real browser copies")
    def test_two_real_browser_copies(self):
        browser = os.environ["ALTER_TEST_BROWSER"]
        extra = ["--arg=--no-sandbox"] if os.geteuid() == 0 else []
        for name in ("Chrome Work", "Chrome Home"):
            self.run_alter("new", name, "--app", browser, "--mode", "chromium", "--arg=--no-first-run", *extra)
            self.run_alter("launch", name)
        # Wait (up to 30 s, CI machines can be slow) until both copies run and have made their own profile.
        profiles = [os.path.join(self.share, "alter", "copies", cid, "data", "profile", "Default")
                    for cid in ("chrome-work", "chrome-home")]
        deadline = time.time() + 30
        while time.time() < deadline:
            out = self.run_alter("list").stdout
            if out.count("running") == 2 and all(os.path.isdir(p) for p in profiles):
                break
            time.sleep(0.5)
        self.assertEqual(out.count("running"), 2, out)
        for p in profiles:
            self.assertTrue(os.path.isdir(p), f"no profile at {p}")
        self.run_alter("stop", "Chrome Home")
        out = self.run_alter("list").stdout
        self.assertIn("Chrome Work  running", out)
        self.assertIn("Chrome Home  stopped", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
