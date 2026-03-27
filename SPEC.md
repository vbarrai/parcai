# parcai — Lightweight shell isolation for AI agents

## Overview

`parcai` spawns an interactive shell where the process is **confined to the current working directory**. The rest of the filesystem is invisible, secrets are unreachable, and destructive system commands fail. When the user exits, modifications are limited to the project dir (APFS clone).

## Usage

```bash
cd my-project
parcai            # launches claude --dangerously-skip-permissions in a sandbox
                  # when claude exits, parcai shows changes and asks to apply

parcai --shell    # drops into a plain isolated shell instead
```

## Design Principles

- **Near-zero overhead**: no VM, no Docker, no daemon. Native OS primitives only.
- **Instant startup**: target <50ms to interactive shell.
- **No root required** (best effort — degrade gracefully if unavailable).
- **Minimal codebase**: single shell script, no compiled language.
- **Hard isolation**: the agent MUST NOT be able to see, read, or modify anything outside `$PWD`.

---

## Threat Model

### What we protect against

| Threat | Example | How it's blocked |
|---|---|---|
| **Reading secrets** | `cat ~/.ssh/id_rsa`, `cat ~/.aws/credentials` | Filesystem restricted to `$PWD` only |
| **Reading other projects** | `ls ~/other-project/` | Path doesn't exist / access denied |
| **Destroying files outside project** | `rm -rf /`, `rm -rf ~` | Filesystem restricted to `$PWD` only |
| **Destroying files inside project** | `rm -rf .` | APFS clone, original intact |
| **Seeing system state** | `ps aux`, `mount`, `cat /etc/passwd` | Sandbox denies process-info |
| **Killing other processes** | `kill -9 <pid>`, `killall` | Sandbox denies signal to external PIDs |
| **Modifying system** | `apt remove`, `brew uninstall`, `launchctl` | No write access outside `$PWD` |
| **Network exfiltration of local files** | Read secret then `curl` it out | Files aren't accessible in the first place. Optional `--no-network` for full lockdown |
| **Spawning persistent daemons** | `nohup malicious &` | Sandbox inherited by children |
| **Escaping via environment** | `$HOME`, `$PATH` manipulation | `$HOME` set to sandbox root, `$PATH` restricted to system bins |
| **Leaking API keys via agent output** | Agent reads `.env` and sends keys in API calls | `--secrets` replaces real tokens with fakes; proxy swaps them back transparently |

### Out of scope

- Kernel exploits, sandbox-exec 0days, side-channel attacks.
- A determined human attacker with knowledge of the sandbox internals.
- Network-based attacks (port scanning, etc.) — use `--no-network` if needed.

---

## CLI Interface

```
parcai [options]
parcai init

Options:
  --allow <path>     Additional path to whitelist (read-only). Repeatable.
  --rw <path>        Additional path to whitelist (read-write). Repeatable.
  --no-network       Deny all network access inside the sandbox.
  --secrets <file>   Enable secret masking proxy using secrets from <file>.
  --secret-log       Write proxy audit log to session directory.
  --apply            Auto-apply changes on exit (skip confirmation).
  --discard          Auto-discard changes on exit (skip confirmation).
  --config <file>    Use a specific config file (default: .parcai.json).
  --shell            Launch a plain shell instead of claude.
  --dry-run          Print the sandbox config without executing.
  --verbose          Show sandbox setup details.
  --help             Show help.
  --version          Show version.

Subcommands:
  init               Generate a starter .parcai.json config file.
```

### Environment Inside the Sandbox

| Variable | Value | Purpose |
|---|---|---|
| `$PARCAI` | `1` | Tools can detect they're sandboxed |
| `$PARCAI_BACKEND` | `sandbox-exec` | Which backend is active |
| `$PARCAI_HOST_CWD` | Original `$PWD` path | Reference to host project path |
| `$HOME` | Clone path | No home dir access |
| `$PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` | Restricted to system binaries |
| `$PARCAI_ALLOWED_DOMAINS` | Comma-separated list (if configured) | Domain allowlist for proxy/agent |
| `$PARCAI_BLOCKED_DOMAINS` | Comma-separated list (if configured) | Domain blocklist for proxy/agent |
| `$HTTPS_PROXY` / `$HTTP_PROXY` | `http://127.0.0.1:<port>` (if `--secrets` active) | Routes traffic through masking proxy |

Shell prompt is prefixed with `[parcai]` to indicate isolation.

---

## Configuration File

Place a `.parcai.json` in your project root to set per-project defaults. CLI flags always override config file values.

### Generate a starter config

```bash
parcai init
```

### Format

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

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `network` | `boolean` | `true` | Set to `false` to disable network (equivalent to `--no-network`) |
| `secrets` | `string\|null` | `null` | Path to secrets file for masking (equivalent to `--secrets <file>`) |
| `secret_log` | `boolean` | `false` | Enable proxy audit log (equivalent to `--secret-log`) |
| `on_exit` | `"ask"\|"apply"\|"discard"` | `"ask"` | What to do with changes on exit |
| `verbose` | `boolean` | `false` | Show sandbox setup details |
| `allow` | `string[]` | `[]` | Additional read-only paths |
| `rw` | `string[]` | `[]` | Additional read-write paths |
| `allowed_domains` | `string[]` | `[]` | Allowlist of domains (mutually exclusive with `blocked_domains`) |
| `blocked_domains` | `string[]` | `[]` | Blocklist of domains (mutually exclusive with `allowed_domains`) |
| `env` | `object` | `{}` | Environment variable overrides injected into the sandbox |

### Example

```json
{
  "network": true,
  "secrets": ".env.real",
  "on_exit": "apply",
  "allow": ["/usr/local/share/data"],
  "env": {
    "NODE_ENV": "test",
    "DEBUG": "1"
  },
  "allowed_domains": ["api.anthropic.com", "api.openai.com"]
}
```

---

## Secret Masking

The `--secrets <file>` option prevents AI agents from seeing real API keys and credentials. Instead of exposing real values, the agent sees fake placeholder tokens. A local proxy transparently swaps fakes back to real values on outbound API calls.

### How it works

1. **Parse** the secrets file (standard `KEY=VALUE` format, like `.env`).
2. **Generate** a fake token for each key: `fake_parcai_<normalized_key>_<random_hex>`.
3. **Build a vault** mapping fake tokens to real values.
4. **Replace** the project's `.env` with fake values inside the sandbox.
5. **Start** `parcai-proxy` (a local HTTPS proxy) that intercepts outbound traffic and swaps fake tokens back to real values.
6. **Set** `HTTPS_PROXY` / `HTTP_PROXY` environment variables so all HTTP traffic routes through the proxy.

### Secrets file format

```
# Comments are supported
OPENAI_API_KEY=sk-abc123...
DATABASE_URL=postgres://user:pass@host/db
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

### Proxy audit log

With `--secret-log` (or `"secret_log": true` in config), the proxy writes an audit log to `~/.parcai/sessions/<hash>/proxy.log` tracking which fake tokens were swapped and when.

### On macOS with `--no-network`

When both `--secrets` and `--no-network` are active, the sandbox profile includes a loopback exception so the agent can still reach the local proxy on `127.0.0.1:<port>`, while all other network access remains blocked.

---

## Session Persistence

parcai preserves Claude's configuration across sessions so context, settings, and credentials survive sandbox restarts.

### Session directory

Each project gets a session directory at:

```
~/.parcai/sessions/<hash>/
```

Where `<hash>` is the first 12 characters of the SHA-256 hash of the project's absolute path.

### What is persisted

On sandbox exit, the following files from `.claude/` inside the sandbox are copied to the session directory:

- `credentials` / `credentials.json`
- `settings.json`
- `settings.local.json`
- `CLAUDE.md`
- Any other `.json` config files

Excluded: `projects/` directory, log files.

### Session lifecycle

1. **First run**: Claude credentials are copied from the global `~/.claude/credentials` into the sandbox.
2. **Subsequent runs**: The full persisted config is restored from `~/.parcai/sessions/<hash>/claude-config/`.
3. **On exit**: Any changes to `.claude/` inside the sandbox are saved back to the session directory.

---

## Network Access

AI agents (Claude, Codex, etc.) require outbound internet access for API calls. Network works by default.

### Requirements

| Requirement | Why |
|---|---|
| DNS resolution | Agents call `api.anthropic.com`, `api.openai.com`, etc. |
| TLS/SSL | All API calls use HTTPS |
| Outbound TCP | HTTP/HTTPS traffic to API servers |
| `--no-network` option | Full lockdown for offline use cases |

### Domain Filtering

parcai supports domain-level network restrictions via config:

- **`allowed_domains`**: Only these domains are reachable (allowlist mode).
- **`blocked_domains`**: These domains are blocked, everything else allowed (blocklist mode).
- The two are mutually exclusive — parcai exits with an error if both are set.

Domain lists are exported as `$PARCAI_ALLOWED_DOMAINS` and `$PARCAI_BLOCKED_DOMAINS` environment variables inside the sandbox.

### Network Implementation

`sandbox-exec` does not filter at the network stack level. With `(allow network*)`:
- DNS resolution works natively
- TLS works natively (system certificates readable)
- All outbound connections are allowed

With `--no-network`: `(deny network*)` blocks all connections including DNS.

When `--secrets` is active with `--no-network`, a loopback exception is added:
```scheme
(allow network-outbound (local tcp "*:<proxy_port>"))
```

| Mode | Behavior |
|---|---|
| Default | `(allow network*)` — everything works |
| `--no-network` | `(deny network*)` — everything blocked |

---

## macOS Backend — `sandbox-exec` + APFS clone

### Why APFS clone?

`sandbox-exec` restricts access but the agent still writes directly to `$PWD`. If it runs `rm -rf .`, the project files are gone. APFS clones (`cp -c`) create an instant, zero-cost copy-on-write duplicate. The agent works on the clone; the original is untouched.

### Flow

```
1. CLONE=$(mktemp -d)/$(basename $PWD)       # resolve symlinks (macOS /tmp -> /private/tmp)
2. cp -c -R $PWD $CLONE                       # APFS clone (falls back to full copy if not APFS)
3. Inject Claude config from session or global ~/.claude/credentials
4. Setup secrets (if --secrets): replace .env, start proxy
5. Create .zshenv/.zshrc with env overrides and domain config
6. Generate .sb profile from template (profiles/macos.sb.tpl)
7. sandbox-exec -f profile.sb /bin/zsh -i     (CWD = CLONE, ZDOTDIR = CLONE)
8. On exit:
   - Persist Claude config to session directory
   - Show diff (M/A/D) excluding .zshenv, .zshrc, .claude/, .cache/, etc.
   - Ask user: "Apply changes to original? [y/N]" (unless --apply or --discard)
   - If yes: rsync CLONE -> original (excluding sandbox artifacts)
   - Cleanup CLONE, profile, and proxy
```

### Sandbox Profile Template

The profile is generated from `profiles/macos.sb.tpl` with these placeholders:

| Placeholder | Replaced with |
|---|---|
| `{{CLONE}}` | Absolute path to the APFS clone directory |
| `{{HOME}}` | User's real `$HOME` (for shell config read-only access) |
| `{{NETWORK_POLICY}}` | `(allow network*)` or `(deny network*)` |
| `{{PROXY_LOOPBACK_RULE}}` | Loopback exception for proxy, or empty |

Additional `--allow` paths append `(allow file-read* (subpath "..."))` rules.
Additional `--rw` paths append `(allow file-read* file-write* (subpath "..."))` rules.

### Key sandbox rules

- **Deny default**: everything blocked unless explicitly allowed.
- **Process exec**: restricted to `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`.
- **Write access**: only the clone directory (`{{CLONE}}`).
- **Read-only access**: system libs, `/etc`, `/tmp`, device files, shell dotfiles.
- **Denied explicitly**: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gcloud`, `~/.kube`, `~/.docker`, `~/.claude`, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/.env`, `~/.netrc`, `~/.npmrc`.
- **Process visibility**: `deny process-info*` with self-exception.
- **IPC**: minimal (`ipc-posix-shm`, `mach-lookup`).

### Guarantees

| Property | Guaranteed? | Mechanism |
|---|---|---|
| Cannot read files outside project | **Yes** | sandbox-exec deny default + subpath whitelist |
| Cannot write files outside project | **Yes** | sandbox-exec deny default + APFS clone |
| Cannot destroy original project | **Yes** | Agent works on APFS clone, not original |
| Cannot see other processes | **Partial** | `deny process-info*` blocks most inspection, but macOS has no PID namespace |
| Cannot kill other processes | **Yes** | `signal (target self)` restricts signals to own process tree |
| Cannot access secrets | **Yes** | Explicit deny on sensitive paths + deny default |
| Children inherit sandbox | **Yes** | sandbox-exec policy is inherited by all child processes |
| Network works | **Yes** | `(allow network*)` + system paths readable for DNS/TLS |
| Claude config persists | **Yes** | Session directory stores `.claude/` config between runs |

### Limitations

- `sandbox-exec` is deprecated by Apple but still functional (macOS 15+). No CLI alternative exists.
- No PID namespace on macOS — `ps aux` is blocked by `deny process-info*` but not 100% airtight.
- APFS clone requires APFS filesystem (default since macOS 10.13, 2017). Falls back to full copy on other filesystems.
- First-time cost: APFS clone is O(1) for disk space but O(n) for metadata of many small files.

---

## Applying Changes

When the user exits the sandbox:

```
parcai: files modified in sandbox:
  M  src/app.ts
  A  src/new-file.ts
  D  src/old-file.ts

parcai: apply changes to original project? [y/N]
```

- rsync the APFS clone to the original, excluding sandbox artifacts (`.zshenv`, `.zshrc`, `.zsh_history`, `.claude/`, `.cache/`, `.config/`, `.local/`, `Library/`, `.claude.json`, `.env` if secrets).
- **If declined**: changes are discarded (clone deleted).
- **`--apply`**: auto-apply without prompting.
- **`--discard`**: auto-discard without prompting.

This ensures the original project is NEVER modified without explicit user consent (unless `--apply` is used).

---

## Verification Checklist

Before shipping, the sandbox must pass:

```bash
# Inside parcai shell, ALL of these must fail:
cat ~/.ssh/id_rsa           # -> error / file not found
ls ~/                       # -> error / only project visible
cat /etc/shadow             # -> error / denied
rm -rf /                    # -> error / no effect on host
ps aux                      # -> denied by sandbox
kill -9 1                   # -> error / denied
touch /tmp/escape           # -> OK (tmp is isolated too)
echo "pwned" > /etc/hosts   # -> error / read-only or denied
curl -s https://api.anthropic.com  # -> works (unless --no-network)
python3 -c "import os; os.listdir('/Users')"  # -> denied

# Network verification:
curl -s https://api.anthropic.com  # -> must succeed (default mode)
parcai --no-network                # then: curl -> must fail

# Secret masking verification (with --secrets):
cat .env                    # -> only fake_parcai_* tokens visible
env | grep API_KEY          # -> only fake_parcai_* tokens
# Real secrets never appear in sandbox environment or files
```

### Automated Tests

| Test file | Scope | Run context |
|---|---|---|
| `tests/test_isolation.sh` | Filesystem, process, network isolation | Inside parcai sandbox |
| `tests/test_secrets.sh` | Secret masking, fake tokens, proxy config | Inside parcai sandbox (with `--secrets`) |
| `tests/test_session.sh` | Claude config persistence across sessions | Outside sandbox (on host) |

---

## Homebrew Distribution

```ruby
class Parcai < Formula
  desc "Lightweight shell isolation for AI agents"
  homepage "https://github.com/vbarrai/parcai"
  url "https://github.com/vbarrai/parcai/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "..."
  license "MIT"

  def install
    bin.install "parcai"
  end

  test do
    assert_match "parcai", shell_output("#{bin}/parcai --version")
  end
end
```

Single shell script — no compilation, no dependencies.

---

## File Structure

```
parcai/
  parcai                  # the shell script (entry point, macOS only)
  profiles/
    macos.sb.tpl          # sandbox-exec profile template with {{placeholders}}
  proxy/
    parcai-proxy          # secret masking proxy binary (optional, for --secrets)
  tests/
    test_isolation.sh     # filesystem/process/network isolation tests
    test_secrets.sh       # secret masking verification tests
    test_session.sh       # Claude config session persistence tests
  SPEC.md                 # this file
```
