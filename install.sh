#!/usr/bin/env bash
# maxagent installer.
#
# Installs maxagent, maxcodex, maxclaude compatibility wrappers, zellij layouts,
# provider profiles, optional per-user systemd services, and zellij if missing.
#
# Quick start (from a clone):     ./install.sh --provider codex
# Or straight from GitHub:        curl -fsSL https://raw.githubusercontent.com/Gadgetguycj/maxclaude/main/install.sh | bash
#
# Options:
#   --provider codex|claude       default provider to configure (default: codex)
#   --workdir DIR                 directory each agent pane opens in (default: $HOME)
#   --codex-profile NAME          add `--profile NAME` to Codex panes
#   --codex-sandbox MODE          add `--sandbox MODE` to Codex panes
#   --codex-approval POLICY       add `--ask-for-approval POLICY` to Codex panes
#   --codex-dangerous-bypass      add Codex dangerous approval/sandbox bypass
#   --yolo, --skip-permissions    start Claude with --dangerously-skip-permissions
#   --safe                        start Claude with normal permission prompts
#   --zellij-version vX.Y.Z       zellij release to fetch if missing (default: v0.44.3)
#   --no-systemd                  skip systemd units; rely on zellij persistence
#   -y, --yes                     non-interactive; take defaults / flags
#   -h, --help                    show this help
set -euo pipefail

REPO="Gadgetguycj/maxclaude"
ZELLIJ_VERSION="v0.44.3"
DEFAULT_PROVIDER="codex"
WORKDIR="$HOME"
CLAUDE_YOLO=""
CLAUDE_MODE_FORCED=""
CODEX_PROFILE=""
CODEX_SANDBOX=""
CODEX_APPROVAL=""
CODEX_DANGEROUS=""
ASSUME_YES=""
WANT_SYSTEMD="auto"

BIN_DIR="$HOME/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
AGENT_CFG_DIR="$CFG_DIR/maxagent"
PROFILE_DIR="$AGENT_CFG_DIR/profiles"
SESSION_DIR="$AGENT_CFG_DIR/sessions"
LAYOUT_DIR="$CFG_DIR/zellij/layouts"
UNIT_DIR="$CFG_DIR/systemd/user"

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say(){ printf '%s\n' "$*"; }
ok(){ printf '%s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn(){ printf '%s!%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die(){ printf '%s✗ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
step(){ printf '\n%s== %s ==%s\n' "$c_bold" "$*" "$c_off"; }
usage(){ if [ -r "$0" ]; then sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'; else echo "maxagent installer — see https://github.com/$REPO"; fi; }

ask(){
  local prompt="$1" default="$2" reply=""
  if [ -n "$ASSUME_YES" ] || [ ! -r /dev/tty ]; then printf '%s' "$default"; return; fi
  printf '%s' "$prompt" > /dev/tty
  IFS= read -r reply < /dev/tty || reply=""
  [ -z "$reply" ] && reply="$default"
  printf '%s' "$reply"
}

shell_quote(){
  local s="$1"
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

find_exe(){
  local name="$1" found=""
  found="$(command -v "$name" 2>/dev/null || true)"
  if [ -z "$found" ]; then
    found="$(bash -lc "command -v $name" 2>/dev/null || true)"
  fi
  if [ -z "$found" ] && [ "$name" = "codex" ]; then
    found="$(find "$HOME/.nvm/versions/node" -maxdepth 4 -name codex -perm -111 2>/dev/null | sort -Vr | head -1 || true)"
  fi
  printf '%s\n' "$found"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider) shift; DEFAULT_PROVIDER="${1:?--provider needs codex or claude}" ;;
    --provider=*) DEFAULT_PROVIDER="${1#*=}" ;;
    --workdir) shift; WORKDIR="${1:?--workdir needs a directory}" ;;
    --workdir=*) WORKDIR="${1#*=}" ;;
    --codex-profile) shift; CODEX_PROFILE="${1:?--codex-profile needs a value}" ;;
    --codex-profile=*) CODEX_PROFILE="${1#*=}" ;;
    --codex-sandbox) shift; CODEX_SANDBOX="${1:?--codex-sandbox needs a value}" ;;
    --codex-sandbox=*) CODEX_SANDBOX="${1#*=}" ;;
    --codex-approval) shift; CODEX_APPROVAL="${1:?--codex-approval needs a value}" ;;
    --codex-approval=*) CODEX_APPROVAL="${1#*=}" ;;
    --codex-dangerous-bypass) CODEX_DANGEROUS=1 ;;
    --yolo|--skip-permissions|--dangerous) CLAUDE_YOLO=1; CLAUDE_MODE_FORCED=1 ;;
    --safe) CLAUDE_YOLO=""; CLAUDE_MODE_FORCED=1 ;;
    --zellij-version) shift; ZELLIJ_VERSION="${1:?--zellij-version needs a value}" ;;
    --zellij-version=*) ZELLIJ_VERSION="${1#*=}" ;;
    --no-systemd) WANT_SYSTEMD="no" ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$DEFAULT_PROVIDER" in codex|claude) ;; *) die "--provider must be codex or claude" ;; esac
case "$CODEX_SANDBOX" in ""|read-only|workspace-write|danger-full-access) ;; *) die "--codex-sandbox must be read-only, workspace-write, or danger-full-access" ;; esac
case "$CODEX_APPROVAL" in ""|untrusted|on-request|never) ;; *) die "--codex-approval must be untrusted, on-request, or never" ;; esac

SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
have_sources(){ [ -f "$SRC_DIR/bin/maxagent" ] && [ -d "$SRC_DIR/layouts" ]; }
if ! have_sources; then
  step "Fetching maxagent sources"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  fetch_to(){
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

uname_s="$(uname -s)"; uname_m="$(uname -m)"
case "$uname_m" in x86_64|amd64) zarch="x86_64" ;; aarch64|arm64) zarch="aarch64" ;; *) zarch="" ;; esac
case "$uname_s" in Linux) zplat="unknown-linux-musl" ;; Darwin) zplat="apple-darwin" ;; *) zplat="" ;; esac

has_systemd(){ command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }
USE_SYSTEMD=""
if [ "$WANT_SYSTEMD" = "no" ]; then
  USE_SYSTEMD=""
elif has_systemd; then
  USE_SYSTEMD=1
else
  [ "$uname_s" = "Linux" ] && warn "no working 'systemctl --user' — falling back to zellij's own session persistence"
fi

step "maxagent installer"
say "  platform     : $uname_s/$uname_m"
say "  install dir  : $BIN_DIR"
say "  config       : $AGENT_CFG_DIR"
say "  layouts      : $LAYOUT_DIR"
say "  default      : $DEFAULT_PROVIDER"
say "  persistence  : $([ -n "$USE_SYSTEMD" ] && echo 'systemd --user service (survives SSH disconnect)' || echo 'zellij background server')"

step "Dependency: zellij"
mkdir -p "$BIN_DIR"
install_zellij_from_release(){
  [ -n "$zarch" ] && [ -n "$zplat" ] || die "no zellij prebuilt for $uname_s/$uname_m — install zellij manually then re-run"
  local asset="zellij-${zarch}-${zplat}.tar.gz" url tmp
  url="https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/${asset}"
  tmp="$(mktemp -d)"
  say "  downloading $asset ($ZELLIJ_VERSION)..."
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
  sysz="$(command -v zellij)"
  ln -sf "$sysz" "$BIN_DIR/zellij"
  ok "linked existing zellij ($sysz -> $BIN_DIR/zellij, $("$sysz" --version 2>/dev/null || echo '?'))"
else
  ans="$(ask "zellij is not installed. Download it now? [Y/n] " "Y")"
  case "$ans" in [Nn]*) die "zellij is required — install it then re-run" ;; esac
  install_zellij_from_release
  ok "installed zellij ($("$BIN_DIR/zellij" --version 2>/dev/null || echo '?'))"
fi

CODEX_BIN="$(find_exe codex)"
CLAUDE_BIN="$(find_exe claude)"
if [ -z "$CODEX_BIN" ]; then
  warn "Codex ('codex') is not on your PATH yet. Install or log in before starting Codex panes."
fi
if [ -z "$CLAUDE_BIN" ]; then
  warn "Claude Code ('claude') is not on your PATH yet. Claude panes will launch once it is available."
fi

step "Configuration"
if [ -z "$ASSUME_YES" ] && [ -r /dev/tty ]; then
  wd="$(ask "Working directory each agent pane opens in [$WORKDIR]: " "$WORKDIR")"
  WORKDIR="${wd/#\~/$HOME}"
fi
if [ ! -d "$WORKDIR" ]; then
  ans="$(ask "Directory '$WORKDIR' does not exist. Create it? [Y/n] " "Y")"
  case "$ans" in [Nn]*) WORKDIR="$HOME" ;; *) mkdir -p "$WORKDIR" || WORKDIR="$HOME" ;; esac
fi
if [ -z "$CLAUDE_MODE_FORCED" ]; then
  say ""
  say "  ${c_bold}Claude --dangerously-skip-permissions${c_off}"
  say "  ${c_dim}Only affects Claude panes. Codex uses safe interactive defaults unless Codex flags are passed.${c_off}"
  ans="$(ask "Start Claude with --dangerously-skip-permissions? [y/N] " "N")"
  case "$ans" in [Yy]*) CLAUDE_YOLO=1 ;; *) CLAUDE_YOLO="" ;; esac
fi

step "Installing files"
install -m 0755 "$SRC_DIR/bin/maxagent" "$BIN_DIR/maxagent"
install -m 0755 "$SRC_DIR/bin/maxcodex" "$BIN_DIR/maxcodex"
install -m 0755 "$SRC_DIR/bin/maxclaude" "$BIN_DIR/maxclaude"
install -m 0755 "$SRC_DIR/bin/maxagent-pane" "$BIN_DIR/maxagent-pane"
install -m 0755 "$SRC_DIR/bin/maxagent-svc" "$BIN_DIR/maxagent-svc"
install -m 0755 "$SRC_DIR/bin/maxclaude-svc" "$BIN_DIR/maxclaude-svc"
ok "commands  -> $BIN_DIR/maxagent, maxcodex, maxclaude"

mkdir -p "$LAYOUT_DIR"
install -m 0644 "$SRC_DIR"/layouts/agent{1,2,3,4}.kdl "$LAYOUT_DIR/"
install -m 0644 "$SRC_DIR"/layouts/cc{1,2,3,4}.kdl "$LAYOUT_DIR/"
ok "layouts   -> $LAYOUT_DIR/agent{1,2,3,4}.kdl (+ legacy cc{1,2,3,4})"

mkdir -p "$PROFILE_DIR" "$SESSION_DIR"
workdir_q="$(shell_quote "$WORKDIR")"
codex_cmd="codex"
codex_path_line="# codex found on PATH"
if [ -n "$CODEX_BIN" ]; then
  codex_cmd="$(shell_quote "$CODEX_BIN")"
  codex_dir="$(dirname "$CODEX_BIN")"
  codex_path_line="export PATH=$(shell_quote "$codex_dir"):\$PATH"
fi
codex_extra=""
[ -n "$CODEX_PROFILE" ] && codex_extra="$codex_extra --profile $(shell_quote "$CODEX_PROFILE")"
[ -n "$CODEX_SANDBOX" ] && codex_extra="$codex_extra --sandbox $(shell_quote "$CODEX_SANDBOX")"
[ -n "$CODEX_APPROVAL" ] && codex_extra="$codex_extra --ask-for-approval $(shell_quote "$CODEX_APPROVAL")"
[ -n "$CODEX_DANGEROUS" ] && codex_extra="$codex_extra --dangerously-bypass-approvals-and-sandbox"
cat > "$PROFILE_DIR/codex.sh" <<EOF
#!/usr/bin/env bash
$codex_path_line
cd $workdir_q 2>/dev/null || cd "\$HOME" || true
if [ -n "\${MAXAGENT_YOLO:-}" ]; then
  exec $codex_cmd --cd $workdir_q$codex_extra --dangerously-bypass-approvals-and-sandbox "\$@"
fi
exec $codex_cmd --cd $workdir_q$codex_extra "\$@"
EOF
chmod 0755 "$PROFILE_DIR/codex.sh"

claude_env="# normal permission prompts"
claude_flags=""
claude_cmd="claude"
if [ -n "$CLAUDE_BIN" ]; then
  claude_cmd="$(shell_quote "$CLAUDE_BIN")"
fi
if [ -n "$CLAUDE_YOLO" ]; then
  claude_env="export IS_SANDBOX=1"
  claude_flags=" --dangerously-skip-permissions"
fi
cat > "$PROFILE_DIR/claude.sh" <<EOF
#!/usr/bin/env bash
$claude_env
cd $workdir_q 2>/dev/null || cd "\$HOME" || true
claude_flags="$claude_flags"
if [ -n "\${MAXAGENT_YOLO:-}" ]; then
  export IS_SANDBOX=1
  case " \$claude_flags " in *" --dangerously-skip-permissions "*) ;; *) claude_flags="\$claude_flags --dangerously-skip-permissions" ;; esac
fi
exec $claude_cmd \$claude_flags "\$@"
EOF
chmod 0755 "$PROFILE_DIR/claude.sh"
ok "profiles  -> $PROFILE_DIR/{codex,claude}.sh"

cat > "$AGENT_CFG_DIR/defaults.env" <<EOF
MAXAGENT_DEFAULT_PROVIDER=$(shell_quote "$DEFAULT_PROVIDER")
MAXAGENT_WORKDIR=$(shell_quote "$WORKDIR")
EOF

if [ -n "$USE_SYSTEMD" ]; then
  mkdir -p "$UNIT_DIR"
  install -m 0644 "$SRC_DIR/systemd/maxagent-named@.service" "$UNIT_DIR/"
  install -m 0644 "$SRC_DIR/systemd/maxclaude@.service" "$UNIT_DIR/"
  install -m 0644 "$SRC_DIR/systemd/maxclaude-named@.service" "$UNIT_DIR/"
  systemctl --user daemon-reload 2>/dev/null || true
  ok "services  -> $UNIT_DIR/maxagent-named@.service (+ legacy maxclaude units)"
  if ! loginctl enable-linger "$USER" >/dev/null 2>&1; then
    warn "could not enable lingering automatically. For sessions to survive logout, run: sudo loginctl enable-linger $USER"
  else
    ok "lingering enabled (sessions survive SSH disconnect)"
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    step "PATH"
    rc="$HOME/.bashrc"; [ -n "${ZSH_VERSION:-}" ] || case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc" ;; esac
    line='export PATH="$HOME/.local/bin:$PATH"'
    if [ -w "$rc" ] || [ ! -e "$rc" ]; then
      grep -qsF "$line" "$rc" 2>/dev/null || { printf '\n# added by maxagent installer\n%s\n' "$line" >> "$rc"; ok "added $BIN_DIR to PATH in $rc"; }
      warn "open a new shell (or run: source $rc) so maxagent is found"
    else
      warn "add this to your shell profile so maxagent is found: $line"
    fi
    ;;
esac

step "Done"
say "Start a Codex session:"
say "  ${c_bold}maxcodex${c_off}        # 2x2 grid of 4 Codex panes"
say "  ${c_bold}maxcodex 2${c_off}      # two Codex panes"
say "  ${c_bold}maxcodex work${c_off}   # named Codex workspace"
say ""
say "Claude compatibility still works:"
say "  ${c_bold}maxclaude${c_off}       # legacy Claude workspace"
say ""
say "Manage:   maxagent ls   |   maxagent attach <n>   |   maxagent close <n>"
say "Detach:   Ctrl-o then d        Move panes: Alt+arrows        Close window: Ctrl-q"
