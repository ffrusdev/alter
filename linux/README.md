# Alter for Linux

Run separate copies of any Linux app, each with its own data, name, icon and app-menu entry. A work Chrome next to a personal one, two Discord accounts, two VS Code setups.

It's one Python 3 script with no dependencies. Python 3 comes with practically every Linux distribution.

## How to use it

### 1. Install

Download **alter-linux.tar.gz** from the [latest release](https://github.com/ffrusdev/alter/releases/latest), then:

```bash
tar xzf alter-linux.tar.gz
cd alter-linux
./install.sh
```

This puts the `alter` command in `~/.local/bin` (no root needed). If your terminal can't find `alter` afterwards, log out and back in.

### 2. Find the app you want to copy

```bash
alter apps          # every app in your app menu, whether it can be copied, and the --app value to use
alter apps chrome   # just the ones matching "chrome"
alter apps --why    # also show the reason for each verdict
```

Each app gets a verdict:

| Verdict | Means |
|---|---|
| **Works** | Browsers, Firefox and Electron apps (Chrome, Brave, VS Code, Discord, Obsidian…), as programs or Flatpaks. Each copy gets its own profile. |
| **Might work** | Apps Alter doesn't know. Each copy gets its own settings folders, which is enough for most apps. |
| **Won't work** | Apps known to allow only one copy (Spotify, Steam and other game launchers, Dropbox), and Snap apps. |

`alter new` warns you before copying an app that won't work, but still makes the copy, in case it works for you.

### 3. Make a copy

```bash
alter new "Chrome Work" --app google-chrome
```

`--app` takes any of these:

| You give | Example |
|---|---|
| a command | `--app google-chrome` |
| a full path | `--app /opt/brave.com/brave/brave` |
| an app-menu entry | `--app code.desktop` |
| a Flatpak app | `--app flatpak:com.discordapp.Discord` |

Alter picks how to keep the copy's data apart (see [Modes](#modes)) and adds the copy to your app menu, with the app's own icon and its own name. Add `--icon tile` for a letter tile like **CW**, or `--icon my.png` for your own picture.

### 4. Open it

Find **Chrome Work** in your app menu and click it (you can pin it to your dock), or:

```bash
alter launch "Chrome Work"
alter launch "Chrome Work" https://example.com   # extra arguments go to the app
```

The copy starts fresh, as if the app had just been installed. Sign in once and it remembers you.

### 5. Manage your copies

```bash
alter list                       # all copies, and which are running
alter info "Chrome Work"         # paths, arguments, environment
alter stop "Chrome Work"         # close it (add --force if it won't close)
alter edit "Chrome Work" --icon tile
alter delete "Chrome Work"       # removes the copy and its data; the original app isn't touched
```

Run `alter <command> --help` for every option.

## Modes

| Mode | Used for | What it does |
|---|---|---|
| `chromium` | Chrome, Chromium, Edge, Brave, Vivaldi, Opera, and Electron apps: VS Code, Cursor, Slack, Discord, Obsidian, Signal… | Own `--user-data-dir` (plus `--extensions-dir` for VS Code-style editors), and its own window class so the dock shows a separate button |
| `firefox` | Firefox, Thunderbird, LibreWolf… | Own `--profile`, with `--no-remote` |
| `redirect` | most other apps (the default) | Points `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME` at the copy's folder |
| `home` | apps that keep settings directly in `~/.something` | Points `HOME` at the copy's folder. Everything is separate, but the copy also won't see your normal dotfiles |
| `none` | | Only a separate launcher, name and icon |

Change it with `alter new ... --mode home` or `alter edit "Name" --mode home`. If a copy still shares settings with the original app in `redirect` mode, the app writes straight to `~/.something`: switch that copy to `home`.

## Where things are

| What | Where |
|---|---|
| A copy's settings, launch script and data | `~/.local/share/alter/copies/<name>/` |
| Data of a Flatpak copy (Flatpak apps may only write inside their own folder) | `~/.var/app/<app id>/alter/<name>/` |
| The app-menu entry | `~/.local/share/applications/alter-<name>.desktop` |

Every process a copy starts carries `ALTER_COPY=<name>` in its environment, which is how `alter list` and `alter stop` find them.

## Limits

- **Snap apps aren't supported**: their sandbox ignores a separate data folder. Use the `.deb`, `.rpm`, tarball or Flatpak version of the app instead.
- **Own dock button**: Chromium-based apps get their own window class (on X11 and XWayland), so docks show them separately. Other apps keep the original app's window class, so some docks group the copy with the original, even though its data is separate.
- Apps with a hard "only one copy" lock still refuse to open twice.
- Copies are separate profiles, not a security sandbox.
- Flatpak support is tested by the generated commands, not yet with real Flatpak apps. [Open an issue](https://github.com/ffrusdev/alter/issues) if one doesn't work.

## Tests

```bash
python3 linux/test_alter.py
# also run two real browser copies (needs a display, e.g. xvfb-run):
ALTER_TEST_BROWSER=$(command -v google-chrome) xvfb-run -a python3 linux/test_alter.py
```
