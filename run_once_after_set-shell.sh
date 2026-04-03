#!/usr/bin/env bash
set -euo pipefail

if [ "$SHELL" != "$(which zsh)" ]; then
  chsh -s "$(which zsh)"
fi
