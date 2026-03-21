# parcai

Lightweight shell isolation for AI agents. Run Claude, Codex, or any AI coding assistant confined to your project directory — no access to secrets, no risk to your system.

## Why?

AI coding agents can read your `~/.ssh/id_rsa`, delete files outside your project, or exfiltrate credentials via API calls. parcai prevents all of that using native OS sandboxing — no Docker, no VM, no daemon.

## Quick start

```bash
# Install (or just clone and add to PATH)
git clone https://github.com/vbarrai/parcai.git
export PATH="$PWD/parcai:$PATH"

# Use it
cd my-project
parcai              # drops into an isolated shell
claude              # runs safely — can only touch my-project/
exit                # back to normal shell, changes reviewed before applying
```

## How it works

| | macOS | Linux |
|---|---|---|
| **Filesystem isolation** | `sandbox-exec` + APFS clone | `unshare` + overlayfs + `pivot_root` |
| **Process isolation** | `deny process-info*` | PID namespace |
| **Write protection** | Agent writes to clone, not original | Agent writes to tmpfs overlay, not original |
| **On exit** | Diff clone vs original, prompt to apply | Diff overlay vs original, prompt to apply |

The original project is **never modified** unless you explicitly approve.

## Installation

### From source

```bash
git clone https://github.com/vbarrai/parcai.git
# Add to PATH, or:
sudo ln -s "$PWD/parcai/parcai" /usr/local/bin/parcai
```

### Homebrew (coming soon)

```bash
brew install vbarrai/tap/parcai
```

### Requirements

- **macOS**: macOS 10.13+ with APFS (default since 2017). Uses `sandbox-exec`.
- **Linux**: Kernel 5.11+ recommended (for unprivileged overlayfs). Uses `unshare`, `util-linux`.
- **No root required** — runs with `--map-root-user` on Linux.

## Usage

### Basic

```bash
cd my-project
parcai
```

You get an isolated shell where:
- Only `my-project/` is accessible (read + write on a copy)
- `~/.ssh`, `~/.aws`, `~/.gnupg`, etc. are invisible
- `$HOME` points to the project directory
- `$PATH` is restricted to system binaries
- Shell prompt shows `[parcai]` to remind you

### Apply or discard changes

When you type `exit`, parcai shows what changed:

```
parcai: files modified in sandbox:
  M  src/app.ts
  A  src/new-file.ts
  D  src/old-file.ts

parcai: apply changes to original project? [y/N]
```

### Disable network

```bash
parcai --no-network
```

All network access is blocked — DNS, TCP, everything. Useful for fully offline sandboxing.

### Whitelist extra paths

```bash
# Read-only access to shared data
parcai --allow /usr/local/share/datasets

# Read-write access to an output directory
parcai --rw /tmp/results
```

### Secret masking

Prevent the agent from ever seeing real API keys:

```bash
parcai --secrets .env
```

This replaces all values in `.env` with fake tokens (`fake_parcai_openai_api_key_a1b2`). A local proxy transparently swaps fakes back to real values on outbound API calls, so the agent works normally without ever seeing the real secrets.

Enable audit logging with:

```bash
parcai --secrets .env --secret-log
```

The log is written to `~/.parcai/sessions/<hash>/proxy.log`.

### Auto-apply or auto-discard

```bash
parcai --apply      # apply changes without asking
parcai --discard    # discard changes without asking
```

### Inspect without running

```bash
parcai --dry-run    # print sandbox config, don't launch
parcai --verbose    # show setup details at startup
```

## Configuration file

Create a `.parcai.json` in your project root to set per-project defaults:

```bash
parcai init
```

This generates:

```json
{
  "network": true,
  "secrets": null,
  "secret_log": false,
  "on_exit": "ask",
  "verbose": false,
  "allow": [],
  "rw": [],
  "allowed_domains": [],
  "blocked_domains": [],
  "env": {}
}
```

### Example config

```json
{
  "secrets": ".env",
  "on_exit": "apply",
  "env": {
    "NODE_ENV": "test"
  },
  "allowed_domains": ["api.anthropic.com", "registry.npmjs.org"]
}
```

CLI flags always override config file values.

| Field | Type | Description |
|---|---|---|
| `network` | `bool` | `false` to disable network |
| `secrets` | `string` | Path to secrets file for masking |
| `secret_log` | `bool` | Enable proxy audit log |
| `on_exit` | `"ask"/"apply"/"discard"` | Behavior on exit |
| `verbose` | `bool` | Show setup details |
| `allow` | `string[]` | Extra read-only paths |
| `rw` | `string[]` | Extra read-write paths |
| `allowed_domains` | `string[]` | Domain allowlist (mutually exclusive with `blocked_domains`) |
| `blocked_domains` | `string[]` | Domain blocklist |
| `env` | `object` | Environment variable overrides |

## Session persistence

parcai preserves Claude's configuration (credentials, settings, CLAUDE.md) across sessions. Config is stored in `~/.parcai/sessions/<hash>/` and automatically restored on the next run in the same project directory.

## Environment variables inside the sandbox

| Variable | Value |
|---|---|
| `PARCAI` | `1` |
| `PARCAI_BACKEND` | `sandbox-exec` or `unshare` |
| `HOME` | Project directory |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` |

## What's blocked

```bash
# All of these fail inside parcai:
cat ~/.ssh/id_rsa           # file not found / denied
ls ~/                       # only project visible
rm -rf /                    # no effect on host
ps aux                      # only sandbox processes (Linux) / denied (macOS)
kill -9 1                   # denied
echo "pwned" > /etc/hosts   # read-only / denied

# This works (unless --no-network):
curl https://api.anthropic.com
```

## Running tests

```bash
# Isolation tests (run inside parcai)
parcai
./tests/test_isolation.sh

# Secret masking tests (run inside parcai --secrets)
parcai --secrets .env.test
./tests/test_secrets.sh

# Session persistence tests (run on host)
./tests/test_session.sh ./parcai
```

## License

MIT
