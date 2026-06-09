#!/usr/bin/env bash
# maxclaude installer.
#
# Installs the `maxclaude` command, its zellij layouts, the per-user systemd
# services (Linux), and — if you don't already have it — the `zellij` terminal
# multiplexer it runs on. Safe to re-run; it just rewrites everything.
#
# Quick start (from a clone):     ./install.sh
# Or straight from GitHub:        curl -fsSL https://raw.githubusercontent.com/Gadgetguycj/maxclaude/main/install.sh | bash
#
# Options:
#   --yolo, --skip-permissions   start Claude with --dangerously-skip-permissions
#   --safe                       start Claude with normal permission prompts (default)
#   --workdir DIR                directory each Claude pane opens in (default: $HOME)
#   --zellij-version vX.Y.Z      zellij release to fetch if it's not installed (default: v0.44.3)
#   --no-systemd                 skip the systemd units (rely on zellij's own persistence)
#   -y, --yes                    non-interactive; take defaults / flags without prompting
#   -h, --help                   show this help
set -euo pipefail

REPO="Gadgetguycj/maxclaude"
ZELLIJ_VERSION="v0.44.3"          # only used when zellij must be downloaded
WORKDIR="$HOME"
YOLO=""                            # empty = safe mode; "1" = --dangerously-skip-permissions
MODE_FORCED=""                     # set if --yolo/--safe passed
ASSUME_YES=""
WANT_SYSTEMD="auto"

BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
LAYOUT_DIR="$CFG_DIR/zellij/layouts"
UNIT_DIR="$CFG_DIR/systemd/user"

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say(){  printf '%s\n' "$*"; }
ok(){   printf '%s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn(){ printf '%s!%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die(){  printf '%s✗ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
step(){ printf '\n%s== %s ==%s\n' "$c_bold" "$*" "$c_off"; }

usage(){ if [ -r "$0" ]; then sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; else echo "maxclaude installer — see https://github.com/$REPO"; fi; }

# Read a line from the real terminal even when the script itself is piped in
# (curl | bash). Falls back to the chosen default when no terminal is attached.
ask(){ # ask <prompt> <default> -> echoes the answer
  local prompt="$1" default="$2" reply=""
  if [ -n "$ASSUME_YES" ] || [ ! -r /dev/tty ]; then printf '%s' "$default"; return; fi
  printf '%s' "$prompt" > /dev/tty
  IFS= read -r reply < /dev/tty || reply=""
  [ -z "$reply" ] && reply="$default"
  printf '%s' "$reply"
}

# ---- args -------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --yolo|--skip-permissions|--dangerous) YOLO=1; MODE_FORCED=1 ;;
    --safe) YOLO=""; MODE_FORCED=1 ;;
    --workdir) shift; WORKDIR="${1:?--workdir needs a directory}" ;;
    --workdir=*) WORKDIR="${1#*=}" ;;
    --zellij-version) shift; ZELLIJ_VERSION="${1:?--zellij-version needs a value}" ;;
    --zellij-version=*) ZELLIJ_VERSION="${1#*=}" ;;
    --no-systemd) WANT_SYSTEMD="no" ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$WORKDIR" in *\"*) die "--workdir cannot contain a double-quote";; esac

# ---- locate sources (self-bootstrap if piped from curl) ---------------------
SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
have_sources(){ [ -f "$SRC_DIR/bin/maxclaude" ] && [ -d "$SRC_DIR/layouts" ]; }
if ! have_sources; then
  step "Fetching maxclaude sources"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  fetch_to(){ # url dest
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
    else die "need curl or wget to download sources"; fi
  }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  fetch_to "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" "$tmp/src.tgz" \
    || die "could not download https://github.com/$REPO"
  tar -xzf "$tmp/src.tgz" -C "$tmp"
  SRC_DIR="$(echo "$tmp"/maxclaude-*)"
  have_sources || die "downloaded archive is missing expected files"
  ok "Downloaded sources to $SRC_DIR"
fi

# ---- platform ---------------------------------------------------------------
uname_s="$(uname -s)"; uname_m="$(uname -m)"
case "$uname_m" in x86_64|amd64) zarch="x86_64";; aarch64|arm64) zarch="aarch64";; *) zarch="";; esac
case "$uname_s" in
  Linux)  zplat="unknown-linux-musl" ;;
  Darwin) zplat="apple-darwin" ;;
  *)      zplat="" ;;
esac

# ---- systemd decision -------------------------------------------------------
has_systemd(){ command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }
USE_SYSTEMD=""
if [ "$WANT_SYSTEMD" = "no" ]; then
  USE_SYSTEMD=""
elif has_systemd; then
  USE_SYSTEMD=1
else
  USE_SYSTEMD=""
  [ "$uname_s" = "Linux" ] && warn "no working 'systemctl --user' — falling back to zellij's own session persistence"
fi

step "maxclaude installer"
say "  platform     : $uname_s/$uname_m"
say "  install dir  : $BIN_DIR"
say "  layouts      : $LAYOUT_DIR"
say "  persistence  : $([ -n "$USE_SYSTEMD" ] && echo 'systemd --user service (survives SSH disconnect)' || echo 'zellij background server')"

# ---- ensure zellij ----------------------------------------------------------
step "Dependency: zellij"
mkdir -p "$BIN_DIR"
install_zellij_from_release(){
  [ -n "$zarch" ] && [ -n "$zplat" ] || die "no zellij prebuilt for $uname_s/$uname_m — install zellij manually then re-run"
  local asset="zellij-${zarch}-${zplat}.tar.gz"
  local url="https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/${asset}"
  local tmp; tmp="$(mktemp -d)"
  say "  downloading $asset ($ZELLIJ_VERSION)…"
  if command -v curl >/dev/null 2>&1; then curl -fL# "$url" -o "$tmp/z.tgz"
  elif command -v wget >/dev/null 2>&1; then wget -q --show-progress -O "$tmp/z.tgz" "$url"
  else die "need curl or wget to download zellij"; fi
  tar -xzf "$tmp/z.tgz" -C "$tmp"
  [ -f "$tmp/zellij" ] || die "zellij binary not found in downloaded archive"
  install -m 0755 "$tmp/zellij" "$BIN_DIR/zellij"
  rm -rf "$tmp"
}
if [ -x "$BIN_DIR/zellij" ]; then
  ok "zellij already at $BIN_DIR/zellij ($("$BIN_DIR/zellij" --version 2>/dev/null || echo '?'))"
elif command -v zellij >/dev/null 2>&1; then
  # Symlink the system zellij to the path the systemd units expect.
  sysz="$(command -v zellij)"
  ln -sf "$sysz" "$BIN_DIR/zellij"
  ok "linked existing zellij ($sysz -> $BIN_DIR/zellij, $("$sysz" --version 2>/dev/null || echo '?'))"
else
  ans="$(ask "zellij is not installed. Download it now? [Y/n] " "Y")"
  case "$ans" in [Nn]*) die "zellij is required — install it then re-run";; esac
  install_zellij_from_release
  ok "installed zellij ($("$BIN_DIR/zellij" --version 2>/dev/null || echo '?'))"
fi

# claude is the whole point; warn but don't block (they may install it next).
if ! command -v claude >/dev/null 2>&1; then
  warn "Claude Code ('claude') isn't on your PATH yet. Install it from https://claude.com/claude-code — the panes will launch it once it's available."
fi

# ---- choices ----------------------------------------------------------------
step "Configuration"
if [ -z "$ASSUME_YES" ] && [ -r /dev/tty ]; then
  wd="$(ask "Working directory each Claude pane opens in [$WORKDIR]: " "$WORKDIR")"
  WORKDIR="${wd/#\~/$HOME}"
fi
if [ ! -d "$WORKDIR" ]; then
  ans="$(ask "Directory '$WORKDIR' doesn't exist. Create it? [Y/n] " "Y")"
  case "$ans" in [Nn]*) WORKDIR="$HOME";; *) mkdir -p "$WORKDIR" || WORKDIR="$HOME";; esac
fi

if [ -z "$MODE_FORCED" ]; then
  say ""
  say "  ${c_bold}--dangerously-skip-permissions${c_off}"
  say "  ${c_dim}Claude runs every tool/command WITHOUT asking for confirmation each time.${c_off}"
  say "  ${c_dim}Convenient for trusted, sandboxed work; risky on a machine you care about.${c_off}"
  ans="$(ask "Start Claude with --dangerously-skip-permissions? [y/N] " "N")"
  case "$ans" in [Yy]*) YOLO=1;; *) YOLO="";; esac
fi
say ""
say "  working dir  : $WORKDIR"
say "  permissions  : $([ -n "$YOLO" ] && echo "${c_ylw}--dangerously-skip-permissions (no prompts)${c_off}" || echo 'normal (Claude asks before acting)')"

# ---- install files ----------------------------------------------------------
step "Installing files"
install -m 0755 "$SRC_DIR/bin/maxclaude"     "$BIN_DIR/maxclaude"
install -m 0755 "$SRC_DIR/bin/maxclaude-svc" "$BIN_DIR/maxclaude-svc"
ok "command   -> $BIN_DIR/maxclaude"

mkdir -p "$LAYOUT_DIR"
install -m 0644 "$SRC_DIR"/layouts/cc1.kdl "$SRC_DIR"/layouts/cc2.kdl \
                "$SRC_DIR"/layouts/cc3.kdl "$SRC_DIR"/layouts/cc4.kdl "$LAYOUT_DIR/"
ok "layouts   -> $LAYOUT_DIR/cc{1,2,3,4}.kdl"

# Render the per-pane launcher with the chosen workdir + permission mode.
if [ -n "$YOLO" ]; then
  env_lines="export IS_SANDBOX=1   # allows --dangerously-skip-permissions to run (e.g. as root)"
  flags="--dangerously-skip-permissions"
else
  env_lines="# normal permission prompts"
  flags=""
fi
content="$(cat "$SRC_DIR/bin/maxclaude-pane.tmpl")"
content="${content//__ENV_LINES__/$env_lines}"
content="${content//__WORKDIR__/$WORKDIR}"
content="${content//__CLAUDE_FLAGS__/$flags}"
printf '%s\n' "$content" > "$BIN_DIR/maxclaude-pane"
chmod 0755 "$BIN_DIR/maxclaude-pane"
ok "pane cmd  -> $BIN_DIR/maxclaude-pane"

if [ -n "$USE_SYSTEMD" ]; then
  mkdir -p "$UNIT_DIR"
  install -m 0644 "$SRC_DIR/systemd/maxclaude@.service"       "$UNIT_DIR/"
  install -m 0644 "$SRC_DIR/systemd/maxclaude-named@.service" "$UNIT_DIR/"
  systemctl --user daemon-reload 2>/dev/null || true
  ok "services  -> $UNIT_DIR/maxclaude{,-named}@.service"
  if ! loginctl enable-linger "$USER" >/dev/null 2>&1; then
    warn "could not enable lingering automatically. For sessions to survive logout, run:  sudo loginctl enable-linger $USER"
  else
    ok "lingering enabled (sessions survive SSH disconnect)"
  fi
fi

# ---- PATH -------------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    step "PATH"
    rc="$HOME/.bashrc"; [ -n "${ZSH_VERSION:-}" ] || case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc";; esac
    line='export PATH="$HOME/.local/bin:$PATH"'
    if [ -w "$rc" ] || [ ! -e "$rc" ]; then
      grep -qsF "$line" "$rc" 2>/dev/null || { printf '\n# added by maxclaude installer\n%s\n' "$line" >> "$rc"; ok "added $BIN_DIR to PATH in $rc"; }
      warn "open a new shell (or run: source $rc) so 'maxclaude' is found"
    else
      warn "add this to your shell profile so 'maxclaude' is found:  $line"
    fi
    ;;
esac

# ---- done -------------------------------------------------------------------
step "Done"
say "Start a session:"
say "  ${c_bold}maxclaude${c_off}        # 2x2 grid of 4 Claude panes"
say "  ${c_bold}maxclaude 2${c_off}      # two panes side by side"
say "  ${c_bold}maxclaude work${c_off}   # a named workspace"
say ""
say "Manage:   maxclaude ls   |   maxclaude attach <n>   |   maxclaude close <n>"
say "Detach:   Ctrl-o then d        Move panes: Alt+arrows        Close window: Ctrl-q"
say ""
say "Re-run this installer any time to change the working dir or permission mode."
