#!/usr/bin/env bash
set -euo pipefail

# Register kitty as terminal
sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/kitty 50

# Set as default
sudo update-alternatives --set x-terminal-emulator /usr/bin/kitty

# XDG (used by some apps)
gsettings set org.gnome.desktop.default-applications.terminal exec kitty || true
