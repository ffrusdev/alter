#!/bin/sh
# Installs Alter for Linux for the current user (no root needed):
#   ~/.local/bin/alter                                   the command
#   ~/.local/share/icons/hicolor/scalable/apps/alter.svg the Alter icon
# Uninstall: rm ~/.local/bin/alter ~/.local/share/icons/hicolor/scalable/apps/alter.svg
# (your copies stay in ~/.local/share/alter until you `alter delete` them).
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin="$HOME/.local/bin"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"

command -v python3 >/dev/null 2>&1 || { echo "Alter needs Python 3. Install it with your package manager (e.g. sudo apt install python3)." >&2; exit 1; }

mkdir -p "$bin" "$icons"
install -m 755 "$here/alter" "$bin/alter"
for logo in "$here/logo/alter-logo.svg" "$here/../logo/alter-logo.svg"; do
  if [ -f "$logo" ]; then install -m 644 "$logo" "$icons/alter.svg"; break; fi
done

echo "Installed: $bin/alter"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "Note: $bin isn't on your PATH yet. Log out and back in, or add this to ~/.profile:"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac
echo
echo "Try it:"
echo "  alter apps                                  # list apps and how to copy them"
echo '  alter new "Chrome Work" --app google-chrome # make a copy'
echo '  alter launch "Chrome Work"                  # start it'
