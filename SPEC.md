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

The `--secrets <file>` option prevents AI agents from seeing real API keys and credentials. The agent only ever sees fake placeholder tokens. A local MITM proxy transparently swaps fakes to real values on outbound requests, and real values back to fakes on inbound responses.

### Architecture

```
Claude (sandbox)                    parcai-proxy (host)               Internet
    │                                    │                               │
    │  "Authorization: Bearer            │                               │
    │   fake_parcai_openai_a1b2"         │                               │
    ├───────────────────────────────────►│                               │
    │                                    │  "Authorization: Bearer       │
    │                                    │   sk-real-key-xxx"            │
    │                                    ├──────────────────────────────►│
    │                                    │                               │
    │                                    │  response body contains       │
    │                                    │  "sk-real-key-xxx"            │
    │                                    │◄──────────────────────────────┤
    │  response body contains            │                               │
    │  "fake_parcai_openai_a1b2"         │                               │
    │◄───────────────────────────────────┤                               │
```

### How it works

1. **Parse** the secrets file (standard `KEY=VALUE` format, like `.env`).
2. **Generate** a fake token for each key: `fake_parcai_<normalized_key>_<random_hex>`.
3. **Build a vault** (`vault.json`) mapping fake tokens ↔ real values.
4. **Replace** the project's `.env` with fake values inside the sandbox.
5. **Start** `parcai-proxy` — a Node.js MITM proxy running on the host (outside the sandbox).
6. **Set** `HTTPS_PROXY` / `HTTP_PROXY` so all traffic routes through the proxy.
7. **Set** `NODE_EXTRA_CA_CERTS` pointing to the proxy's CA certificate for HTTPS trust.

### MITM Proxy details

`parcai-proxy` is a single-file Node.js script (`proxy/parcai-proxy`) with zero external dependencies.

**HTTP requests**: the proxy intercepts, replaces fake→real in headers and body, forwards to the server, then replaces real→fake in the response before returning to the client.

**HTTPS requests (CONNECT)**: the proxy performs TLS man-in-the-middle:
1. Accepts the `CONNECT` tunnel request.
2. Generates a TLS certificate for the target hostname, signed by its own CA.
3. Performs TLS handshake with the client using the generated cert.
4. Opens a TLS connection to the real server.
5. Parses HTTP within the tunnel — same fake→real / real→fake replacement on both directions.

**CA certificate**: auto-generated on first run and stored in `~/.parcai/ca/`. The CA cert is copied to `/tmp/parcai-proxy-ca.crt` and trusted via `NODE_EXTRA_CA_CERTS`.

**HTTP/2**: disabled (forced to HTTP/1.1) to simplify MITM parsing.

**Compression**: `Accept-Encoding` is stripped from outbound requests to force uncompressed responses, avoiding the need to decompress/recompress for token replacement.

### Vault format

```json
{
  "fake_parcai_openai_api_key_a1b2c3d4": {
    "real": "sk-abc123...",
    "key": "OPENAI_API_KEY"
  },
  "fake_parcai_database_url_e5f6a7b8": {
    "real": "postgres://user:pass@host/db",
    "key": "DATABASE_URL"
  }
}
```

Tokens are sorted by length (longest first) before replacement to prevent partial matches.

### Secrets file format

```
# Comments are supported
OPENAI_API_KEY=sk-abc123...
DATABASE_URL=postgres://user:pass@host/db
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

### Proxy audit log

With `--secret-log` (or `"secret_log": true` in config), the proxy writes a JSON-lines audit log tracking which secrets were swapped:

```json
{"ts":"2026-03-27T10:00:00Z","dir":"outbound","key":"OPENAI_API_KEY","host":"api.openai.com","path":"/v1/chat/completions"}
{"ts":"2026-03-27T10:00:01Z","dir":"inbound","key":"OPENAI_API_KEY","host":"api.openai.com","path":"/v1/chat/completions"}
```

Token values are **never** logged — only the key name, direction, host, and path.

### On macOS with `--no-network`

When both `--secrets` and `--no-network` are active, the sandbox profile includes a loopback exception so the agent can still reach the local proxy on `127.0.0.1:<port>`, while all other network access remains blocked.

### Guarantees

| Property | Guaranteed? | Mechanism |
|---|---|---|
| Agent never sees real secrets | **Yes** | `.env` replaced with fakes, all responses masked |
| API calls work normally | **Yes** | Proxy swaps real tokens into outbound requests |
| Agent cannot bypass proxy | **Yes** | `HTTPS_PROXY`/`HTTP_PROXY` set in sandbox environment |
| Secrets never logged | **Yes** | Audit log records key names only, never values |
| HTTPS traffic inspectable | **Yes** | MITM with auto-generated CA cert per hostname |

---

## Session Persistence

parcai preserves Claude's configuration across sessions so credentials, settings, and state survive sandbox restarts. The sandbox config is **completely isolated** from the host's `~/.claude` — nothing is ever copied from the host.

### Persistent Claude home

All Claude configuration is stored in a dedicated directory:

```
~/.parcai/claude-home/
```

This acts as Claude's "home" across all parcai sessions. It contains:

| Path | Content |
|------|---------|
| `~/.parcai/claude-home/.claude/` | Credentials, settings, JSON configs |
| `~/.parcai/claude-home/.claude.json` | Claude state file (startup count, install method, tips, etc.) |
| `~/.parcai/claude-home/Library/Application Support/claude/` | Native app state |

### What is persisted

On sandbox exit, these are synced from the clone to `~/.parcai/claude-home/`:

- **`.claude/`**: all files except `projects/`, `debug/`, `file-history/`, `cache/`, `downloads/`, and `*.log`
- **`.claude.json`**: Claude's global state file
- **`Library/Application Support/claude/`**: native app data

### Session lifecycle

1. **First run**: `~/.parcai/claude-home/` is empty — Claude starts from scratch, must authenticate.
2. **On exit**: config synced from clone to `~/.parcai/claude-home/`.
3. **Subsequent runs**: config restored from `~/.parcai/claude-home/` into clone. No re-authentication needed.

### Per-project session directory

Each project also gets a session directory at `~/.parcai/sessions/<hash>/` (hash = first 12 chars of SHA-256 of project path). Currently used for proxy audit logs when `--secret-log` is active.

### Isolation guarantee

The host's `~/.claude` is **never read** by parcai. It is also **explicitly denied** in the sandbox profile (`deny file-read* file-write* (subpath "{{HOME}}/.claude")`). The sandbox Claude and the host Claude have completely separate configurations.

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
3. Inject Claude config from ~/.parcai/claude-home/ (or start fresh if first run)
4. Setup secrets (if --secrets): replace .env, generate vault, start MITM proxy
5. Resolve claude binary path, create .zshenv (PATH, proxy env) and .zshrc (launch claude)
6. Generate .sb profile from template (profiles/macos.sb.tpl)
7. sandbox-exec -f profile.sb /bin/zsh -i     (HOME = CLONE, ZDOTDIR = CLONE)
8. On exit:
   - Persist Claude config to ~/.parcai/claude-home/
   - Show diff (M/A/D) excluding .zshenv, .zshrc, .claude/, .cache/, Library/, etc.
   - Ask user: "Apply changes to original? [y/N]" (unless --apply or --discard)
   - If yes: rsync CLONE -> original (excluding sandbox artifacts)
   - Cleanup CLONE, profile, and proxy
```

### Sandbox Profile Template

The profile is generated from `profiles/macos.sb.tpl` with these placeholders:

| Placeholder | Replaced with |
|---|---|
| `{{CLONE}}` | Absolute path to the APFS clone directory |
| `{{HOME}}` | User's real `$HOME` (for deny rules and broad read) |
| `{{NETWORK_POLICY}}` | `(allow network*)` or `(deny network*)` |
| `{{PROXY_LOOPBACK_RULE}}` | Loopback exception for proxy, or empty |
| `{{CLAUDE_EXEC_RULE}}` | `(literal "/path/to/claude")` or empty if `--shell` |

Additional `--allow` paths append `(allow file-read* (subpath "..."))` rules.
Additional `--rw` paths append `(allow file-read* file-write* (subpath "..."))` rules.

### Key sandbox rules

- **Deny default**: everything blocked unless explicitly allowed.
- **Process exec**: restricted to `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`, + claude binary (resolved dynamically).
- **Write access**: only the clone directory (`{{CLONE}}`) + `/tmp` + `/dev/null`,`/dev/tty`.
- **Read-only access**: `/` (literal, for path resolution), system paths (`/usr`, `/bin`, `/sbin`, `/opt`, `/Library`, `/System`, `/etc`, `/var`, `/tmp`, `/dev`), **entire user home** `{{HOME}}`.
- **Denied explicitly** (overrides broad home read): credentials (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.claude`, `~/.env`, `~/.netrc`, `~/.npmrc`, `~/.git-credentials`), cloud configs (`~/.config/gcloud`, `~/.config/gh`, `~/.azure`, `~/.oci`, `~/.terraform.d`), package managers (`~/.cargo`, `~/.npm`, `~/.bun`, `~/.nvm`, `~/.pyenv`, `~/.gem`, `~/.m2`, `~/.gradle`), personal folders (`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`), shell history files, other project dirs (`~/Workspace`, `~/Projects`, `~/repos`, `~/src`, `~/code`, `~/dev`).
- **TTY access**: `file-ioctl` on `/dev/tty` and `/dev/ttys*` (needed for setRawMode).
- **Process visibility**: `deny process-info*` with self-exception.
- **IPC**: minimal (`ipc-posix-shm`, `mach-lookup`).

**Note:** The broad home read (`subpath {{HOME}}`) is required because Claude needs to resolve symlinks (`~/.local/bin/claude` → `~/.local/share/claude/versions/...`) and access `~/Library/`. Sensitive directories are blocked by explicit deny rules which take precedence.

### What remains readable

The broad home read rule (`allow file-read* (subpath "{{HOME}}")`) means that any directory under `$HOME` that is **not** in the explicit deny list above remains readable inside the sandbox. Examples:

- `~/.config/` (except `~/.config/gcloud` and `~/.config/gh`, which are denied)
- `~/Library/` (needed for macOS system frameworks, fonts, TLS certificates, etc.)
- `~/.local/` (needed to resolve the `claude` binary symlink chain)
- `~/.gitconfig` (needed for git operations inside the sandbox)

This is required for Claude and standard dev tools to function correctly. If you need to restrict additional paths, you can:

- Use the `--deny <path>` CLI flag to add deny rules at launch.
- Add paths to the `deny` array in your project's `.parcai.json` config file.

Custom deny rules take precedence over the broad home read, just like the built-in deny list.

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
    parcai-proxy          # MITM proxy for secret masking (Node.js, zero deps)
  tests/
    test_isolation.sh     # filesystem/process/network isolation tests
    test_secrets.sh       # secret masking verification tests
    test_session.sh       # Claude config session persistence tests
  SPEC.md                 # this file
```
