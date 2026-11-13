**Alter 1.1.0 adds Alter for Linux.** Run separate copies of any app, each with its own sign-in, settings, icon and launcher, now on Windows and Linux.

### Downloads
- **Windows: Alter.zip.** Extract it anywhere, then double-click **Alter.exe**. If Windows shows "Windows protected your PC", click **More info**, then **Run anyway** (Alter isn't signed).
- **Linux: alter-linux.tar.gz.** `tar xzf alter-linux.tar.gz && cd alter-linux && ./install.sh`, then `alter new "Chrome Work" --app google-chrome`.

How to use it: [Windows](https://github.com/ffrusdev/alter#how-to-use-it) · [Linux](https://github.com/ffrusdev/alter/blob/main/linux/README.md)

### New: Alter for Linux
- One Python 3 script, no dependencies, installs to `~/.local/bin` without root
- `alter new`, `list`, `launch`, `stop`, `info`, `edit`, `delete`, and `apps` to find what to copy
- Copies of Chrome, Chromium, Edge, Brave, Firefox, Electron apps (VS Code, Slack, Discord, Obsidian…), Flatpak apps and most other apps
- Each copy gets its own data folder and its own app-menu entry with its own name and icon; Chromium-based copies also get their own dock button
- Tested on every release with two real Chrome copies running side by side

### Windows
No changes since 1.0.0.
