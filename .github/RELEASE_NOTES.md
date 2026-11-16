**Alter 1.2.0: Browse shows which apps can be copied.**

### Downloads
- **Windows: Alter.zip.** Extract it anywhere, then double-click **Alter.exe**. If Windows shows "Windows protected your PC", click **More info**, then **Run anyway** (Alter isn't signed).
- **Linux: alter-linux.tar.gz.** `tar xzf alter-linux.tar.gz && cd alter-linux && ./install.sh`, then `alter apps` to see what you can copy.

How to use it: [Windows](https://github.com/ffrusdev/alter#how-to-use-it) · [Linux](https://github.com/ffrusdev/alter/blob/main/linux/README.md)

### New on Windows
- **Browse** now opens a list of the apps in your Start Menu, including Store apps like the Claude desktop app, instead of a file picker
- Each app has a badge and a one-line reason:
  - **Works**: browsers, Firefox and Electron apps (Chrome, Edge, VS Code, Discord, Claude…)
  - **Might work**: apps Alter doesn't know
  - **Won't work**: apps that only allow one copy (Spotify, game launchers, OneDrive, Office) and Store apps without a launch alias. You can still try them; Alter asks first.
- Search, filter chips (All / Works / Might work / Won't work, with counts) and **Sort by** (Works first, or by name)
- After you pick an app, the form shows its verdict under the App field
- **Other .exe…** still opens the normal file picker

### New on Linux
- `alter apps` shows the same verdicts, Works first. Add `--why` for the reasons, `--only works|maybe|no` to filter, `--sort name|name-desc` to sort by name
- `alter new` warns before copying an app that won't work
