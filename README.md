# parcai

Lightweight shell isolation for AI agents. Run Claude, Codex, or any AI coding assistant confined to your project directory — no access to secrets, no risk to your system.

## Why?

AI coding agents can read your `~/.ssh/id_rsa`, delete files outside your project, or exfiltrate credentials via API calls. parcai prevents all of that using macOS native sandboxing (`sandbox-exec` + APFS clone) — no Docker, no VM, no daemon.

## Quick start

```bash
# Install
curl -sSL https://raw.githubusercontent.com/vbarrai/parcai/main/install.sh | bash

# Use it
cd my-project
parcai              # launches claude in a sandbox — can only touch my-project/
                    # when claude exits, parcai shows changes and asks to apply
```

## How it works

| Feature | Mechanism |
|---|---|
| **Filesystem isolation** | `sandbox-exec` + APFS clone |
| **Process isolation** | `deny process-info*` |
| **Write protection** | Agent writes to clone, not original |
| **On exit** | Diff clone vs original, prompt to apply |

The original project is **never modified** unless you explicitly approve.

## Installation

### One-liner

```bash
curl -sSL https://raw.githubusercontent.com/vbarrai/parcai/main/install.sh | bash
```

Installs to `~/.local/share/parcai/` and symlinks to `~/.local/bin/parcai`.

You can customize the install paths:

```bash
PARCAI_INSTALL_DIR=/opt/parcai PARCAI_BIN_DIR=/usr/local/bin \
  curl -sSL https://raw.githubusercontent.com/vbarrai/parcai/main/install.sh | bash
```

To install a specific version:

```bash
PARCAI_VERSION=v0.1.0 curl -sSL https://raw.githubusercontent.com/vbarrai/parcai/main/install.sh | bash
```

To upgrade, run the same command — it detects and replaces the existing installation:

```bash
curl -sSL https://raw.githubusercontent.com/vbarrai/parcai/main/install.sh | bash
# ▸ Upgrading from parcai 0.1.0
# ▸ Upgraded: parcai 0.1.0 → parcai 0.2.0
```

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

- **macOS 10.13+** with APFS (default since 2017). Uses `sandbox-exec`.

## Usage

### Basic

```bash
cd my-project
parcai
```

This launches `claude --dangerously-skip-permissions` inside an isolated sandbox. When claude exits, parcai automatically exits and shows you what changed.

The sandbox ensures:
- Only `my-project/` is accessible (read + write on a copy)
- `~/.ssh`, `~/.aws`, `~/.gnupg`, etc. are invisible
- `$HOME` points to the project directory
- `$PATH` is restricted to system binaries

### Shell mode

If you want a plain interactive shell instead of claude:

```bash
parcai --shell
```

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

parcai masks secrets listed in `.parcai.json`. On first launch, parcai creates a default config that covers common secret files (`.env`, `.env.local`, `.env.production`, `credentials.json`, etc.). Only files that actually exist in your project are masked.

```bash
parcai              # reads .parcai.json, masks any listed files that exist
```

You can also add files via CLI:

```bash
parcai --secrets .env.custom                   # add a specific file
parcai --secrets .env --secrets .env.local      # add multiple files
```

The secrets files use standard `KEY=VALUE` format:

```bash
# .env (your real secrets)
OPENAI_API_KEY=sk-abc123...
DATABASE_URL=postgres://user:pass@host/db
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
STRIPE_SECRET_KEY=sk_live_...
```

When parcai starts:

1. Each secret value is replaced by a random fake token (`fake_parcai_openai_api_key_a1b2`). **Tokens are regenerated at every launch** — the agent never sees the same fake twice.
2. The agent sees only fake tokens in all masked files and in memory.
3. A local MITM proxy intercepts all HTTP/HTTPS traffic:
   - **Outbound**: fake tokens are swapped to real values before reaching the API server
   - **Inbound**: real values in responses are swapped back to fake tokens

The agent works normally without ever seeing the real secrets. HTTPS is intercepted via a per-hostname TLS certificate signed by an auto-generated CA.

You can also configure it in `.parcai.json`:

```json
{
  "secrets": [".env", ".env.local"]
}
```

Or as a single file:

```json
{
  "secrets": ".env.prod"
}
```

Enable audit logging to see which secrets are used and when:

```bash
parcai --secret-log
```

The log is written to `~/.parcai/sessions/<hash>/proxy.log` and records which keys were swapped, to which hosts, but **never the actual secret values**.

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
| `PARCAI_BACKEND` | `sandbox-exec` |
| `HOME` | Project directory |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` |

## What's blocked

```bash
# All of these fail inside parcai:
cat ~/.ssh/id_rsa           # file not found / denied
ls ~/                       # only project visible
rm -rf /                    # no effect on host
ps aux                      # denied by sandbox
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

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Abort trap: 6` | Claude binary not in the sandbox-exec whitelist | Ensure `claude` is installed and available in `PATH` so parcai can resolve and whitelist it |
| `setRawMode failed with errno: 1` | TTY not available inside the sandbox | Fixed in a recent release. Update parcai to the latest version |
| `installMethod is native, but claude command not found` | Claude's `~/.local/bin` was not included in the sandbox `PATH` | Fixed in a recent release. Update parcai to the latest version |
| `can't set tty pgrp: operation not permitted` | Sandbox was blocking TTY process-group control | Fixed in a recent release. Update parcai to the latest version |
| Proxy hangs on startup | Node.js is not installed | `--secrets` requires Node.js for the MITM proxy. Install Node.js and try again |
| `parcai-proxy: domain "X" is not allowed` | Domain blocked by network filtering config | Check `allowed_domains` / `blocked_domains` in `.parcai.json` or CLI flags and add the domain if needed |

## License

MIT
