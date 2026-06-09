# maxagent

Run **1-4 Codex or Claude panes in one terminal** that survive closing your SSH
connection. One command opens a [zellij](https://zellij.dev) session laid out as
a grid of coding-agent panes; detach, reconnect later, and the session is still
there.

```bash
maxcodex          # 2x2 grid of 4 Codex panes
maxcodex 2        # two Codex panes, side by side
maxcodex work     # named Codex workspace
maxclaude         # Claude compatibility command
```

```
┌───────────────┬───────────────┐
│   agent #1    │   agent #2    │
├───────────────┼───────────────┤
│   agent #3    │   agent #4    │
└───────────────┴───────────────┘
        maxagent  (session: codex4)
```

## Install

From a clone:

```bash
git clone https://github.com/Gadgetguycj/maxclaude.git
cd maxclaude
./install.sh --provider codex
```

Or one line from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/Gadgetguycj/maxclaude/main/install.sh | bash
```

The installer:

- installs `maxagent`, `maxcodex`, and the compatibility `maxclaude` command;
- installs zellij into `~/.local/bin` if zellij is missing;
- writes provider profiles under `~/.config/maxagent/profiles`;
- installs neutral `agent{1,2,3,4}` layouts plus legacy `cc{1,2,3,4}` layouts;
- installs per-user systemd services on Linux when available;
- adds `~/.local/bin` to your `PATH` if needed.

### Non-Interactive Install

```bash
./install.sh --yes --provider codex --workdir "$HOME/code"
./install.sh --yes --provider codex --codex-sandbox workspace-write
./install.sh --yes --provider claude --yolo
```

| flag | meaning |
|------|---------|
| `--provider codex\|claude` | default provider for `maxagent` |
| `--workdir DIR` | directory each pane opens in |
| `--codex-profile NAME` | pass `--profile NAME` to Codex |
| `--codex-sandbox MODE` | pass `--sandbox MODE` to Codex |
| `--codex-approval POLICY` | pass `--ask-for-approval POLICY` to Codex |
| `--codex-dangerous-bypass` | pass Codex's dangerous approval/sandbox bypass flag |
| `--yolo`, `--skip-permissions` | start Claude with `--dangerously-skip-permissions` |
| `--safe` | start Claude with normal permission prompts |
| `--zellij-version vX.Y.Z` | zellij release to fetch when missing |
| `--no-systemd` | skip systemd units; rely on zellij's own persistence |
| `-y`, `--yes` | take defaults/flags without prompting |

Codex defaults are intentionally safe and interactive. The dangerous Codex
bypass is only used when explicitly requested.

## Requirements

- **Codex CLI** (`codex` on your `PATH`) for Codex panes.
- **Claude Code** (`claude` on your `PATH`) for Claude panes.
- **zellij** - installed automatically if missing.
- **Linux with `systemctl --user`** for the strongest "survives SSH disconnect"
  behavior via systemd linger. macOS and non-systemd hosts use zellij's own
  background server.

## Usage

| command | what it does |
|---------|--------------|
| `maxcodex` | open/attach the 4-pane Codex grid |
| `maxcodex 1` \| `2` \| `3` \| `4` | open/attach an N-pane Codex session |
| `maxcodex <name>` | open/attach a named Codex workspace |
| `maxcodex <name> N` | named Codex workspace with N panes |
| `maxagent codex <name> N` | explicit provider form |
| `maxagent claude <name> N` | explicit Claude provider form |
| `maxclaude` | legacy Claude command; keeps `max1`-`max4` session names |
| `maxagent ls` | list live sessions, numbered, with status flags |
| `maxagent attach <n\|name>` | attach session #n from `ls`, or by name |
| `maxagent close <n\|name>` | close session #n from `ls`, or by name |
| `maxagent close all` | close every session |
| `maxagent prune` | garbage-collect dead/exited session ghosts |

Inside a session:

- **Detach**: `Ctrl-o` then `d`
- **Move between panes**: `Alt`+arrow keys
- **Close the whole window**: `Ctrl-q`

Re-running the same name/number re-attaches.

## How It Works

- `~/.local/bin/maxagent` owns zellij session management.
- `~/.local/bin/maxcodex` and `~/.local/bin/maxclaude` are provider wrappers.
- `~/.config/maxagent/profiles/codex.sh` execs `codex --cd <workdir>`.
- `~/.config/maxagent/profiles/claude.sh` execs `claude`.
- `~/.config/maxagent/sessions/*.env` records provider and pane count per
  zellij session.
- `~/.local/bin/maxagent-pane` runs inside each pane and dispatches to the
  session's provider profile.
- `~/.config/zellij/layouts/agent{1,2,3,4}.kdl` define the neutral layouts.
- `~/.config/zellij/layouts/cc{1,2,3,4}.kdl` are kept for legacy compatibility.
- `~/.config/systemd/user/maxagent-named@.service` starts background sessions on
  systemd hosts. Legacy `maxclaude@.service` files are also installed.

Sessions do **not** survive a full reboot. They survive logging out or SSH
disconnects when systemd linger or zellij background persistence is available.

## Uninstall

```bash
./uninstall.sh
./uninstall.sh --remove-zellij
```

## License

[MIT](LICENSE).
