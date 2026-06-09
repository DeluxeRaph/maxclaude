#!/usr/bin/env bash
# maxclaude uninstaller. Stops any running sessions and removes the files the
# installer created. Leaves zellij itself in place (it may be used elsewhere);
# pass --remove-zellij to delete ~/.local/bin/zellij too.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
LAYOUT_DIR="$CFG_DIR/zellij/layouts"
UNIT_DIR="$CFG_DIR/systemd/user"
REMOVE_ZELLIJ=""

for a in "$@"; do case "$a" in --remove-zellij) REMOVE_ZELLIJ=1;; -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0;; esac; done

# Stop sessions + units (best effort).
if command -v "$BIN_DIR/maxclaude" >/dev/null 2>&1 || [ -x "$BIN_DIR/maxclaude" ]; then
  "$BIN_DIR/maxclaude" kill all >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  for n in 1 2 3 4; do systemctl --user disable --now "maxclaude@${n}.service" >/dev/null 2>&1 || true; done
  systemctl --user list-units 'maxclaude-named@*' --all --no-legend 2>/dev/null | awk '{print $1}' \
    | while read -r u; do systemctl --user disable --now "$u" >/dev/null 2>&1 || true; done
fi

rm -f "$BIN_DIR/maxclaude" "$BIN_DIR/maxclaude-svc" "$BIN_DIR/maxclaude-pane"
rm -f "$LAYOUT_DIR"/cc{1,2,3,4}.kdl
rm -f "$UNIT_DIR/maxclaude@.service" "$UNIT_DIR/maxclaude-named@.service"
rm -rf "$CFG_DIR/maxclaude"
command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null || true

if [ -n "$REMOVE_ZELLIJ" ]; then rm -f "$BIN_DIR/zellij"; echo "removed $BIN_DIR/zellij"; fi
echo "maxclaude uninstalled. (PATH line in your shell rc, if added, was left in place — remove it by hand if you like.)"
