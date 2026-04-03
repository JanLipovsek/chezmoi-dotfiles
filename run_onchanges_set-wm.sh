#!/usr/bin/env bash
set -euo pipefail

USER_NAME="$(whoami)"
USER_FILE="/var/lib/AccountsService/users/$USER_NAME"

sudo mkdir -p /var/lib/AccountsService/users

sudo bash -c "cat > $USER_FILE" <<EOF
[User]
XSession=i3
EOF
