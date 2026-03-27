# CLAUDE.md — Project Guide for AI Assistants

## What is parcai?

parcai is a macOS-only shell isolation tool for AI agents (Claude, Codex, etc.). It confines the agent to the current project directory using native OS sandboxing — no Docker, no VM, no daemon.

**Core stack:** bash script (`parcai`) + sandbox-exec + APFS clone + Node.js MITM proxy

## Architecture

```
parcai (808 lines bash)
  ├── profiles/macos.sb.tpl    — sandbox-exec profile template (122 lines)
  ├── proxy/parcai-proxy       — MITM proxy for secret masking (Node.js, 562 lines)
  └── tests/                   — isolation, secrets, session tests
```

## How it works — Lifecycle

```
parcai [options]
  → check_platform (macOS only)
  → load .parcai.json + CLI flags
  → create APFS clone of $PWD (cp -c -R)
  → inject Claude config from ~/.parcai/claude-home/ (or start fresh)
  → [if --secrets] generate fake tokens, start MITM proxy on localhost
  → generate sandbox profile from template (substitute placeholders)
  → create .zshenv (restricted PATH, proxy env) and .zshrc (launches claude)
  → sandbox-exec -f profile.sb /bin/zsh -i (HOME=$CLONE, ZDOTDIR=$CLONE)
  → [agent runs, all traffic routed through proxy if --secrets]
  → on exit:
      → persist Claude config to ~/.parcai/claude-home/
      → show diff (M/A/D) between clone and original
      → prompt apply/discard
      → cleanup clone, profile, proxy
```

## Key directories

| Path | Purpose |
|------|---------|
| `~/.parcai/claude-home/` | Persistent Claude config (isolated from real ~/.claude) |
| `~/.parcai/claude-home/.claude/` | Credentials, settings, json configs |
| `~/.parcai/claude-home/.claude.json` | Claude state file (numStartups, installMethod, etc.) |
| `~/.parcai/claude-home/Library/Application Support/claude/` | Native app state |
| `~/.parcai/ca/` | Auto-generated CA cert+key for MITM proxy |
| `~/.parcai/sessions/<hash>/` | Per-project session directory (hash of pwd) |
| `/tmp/parcai-proxy-ca.crt` | CA cert copy (referenced by NODE_EXTRA_CA_CERTS) |

## Sandbox profile (profiles/macos.sb.tpl)

**Philosophy:** `(deny default)` — everything blocked, then whitelist.

**Writable:** only `{{CLONE}}` (the APFS clone) + `/tmp` + `/dev/null`,`/dev/tty`

**Readable:** system paths (`/usr`, `/bin`, `/Library`, `/System`, `/opt`, `/etc`, `/var`, `/tmp`, `/dev`) + `{{HOME}}` (broad read for symlink resolution)

**Explicitly denied (overrides broad home read):**
- Credentials: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.claude`, `~/.env`, `~/.netrc`, `~/.npmrc`, `~/.git-credentials`
- Cloud: `~/.config/gcloud`, `~/.config/gh`, `~/.config/op`, `~/.azure`, `~/.oci`, `~/.terraform.d`
- Package managers: `~/.cargo`, `~/.npm`, `~/.bun`, `~/.nvm`, `~/.pyenv`, `~/.gem`, `~/.m2`, `~/.gradle`
- Personal: `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`
- History: `~/.zsh_history`, `~/.bash_history`, `~/.node_repl_history`, `~/.python_history`, `~/.psql_history`, `~/.mysql_history`, `~/.irb_history`, `~/.lesshst`, `~/.sh_history`
- Other projects: `~/Workspace`, `~/Projects`, `~/repos`, `~/src`, `~/code`, `~/dev`

**Exec:** `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin` + claude binary (resolved dynamically)

**Placeholders:** `{{CLONE}}`, `{{HOME}}`, `{{NETWORK_POLICY}}`, `{{PROXY_LOOPBACK_RULE}}`, `{{CLAUDE_EXEC_RULE}}`

## Secret masking proxy (proxy/parcai-proxy)

Node.js MITM proxy, zero external dependencies. Stdlib only: http, https, tls, crypto, net, fs.

**Flow:**
1. parcai generates vault.json (fake_parcai_xxx → real values)
2. .env in clone replaced with fake tokens
3. Proxy starts on localhost, prints `PORT=<N>\nPID=<N>` to stdout, closes stdout
4. HTTPS_PROXY/HTTP_PROXY set in sandbox env
5. All outbound: fake→real replacement in headers+body
6. All inbound: real→fake replacement in headers+body
7. HTTPS: TLS MITM with per-hostname cert signed by auto-generated CA
8. HTTP/2 disabled (forced HTTP/1.1), Accept-Encoding stripped

**Audit log format (JSON-lines):**
```json
{"ts":"...","type":"request","method":"GET","host":"api.openai.com","path":"/v1/...","proto":"https"}
{"ts":"...","type":"swap","dir":"outbound","key":"OPENAI_API_KEY","host":"api.openai.com","path":"/v1/..."}
```

## Important implementation details

- **HOME=$CLONE_DIR** inside sandbox — NOT the real home. This is critical for isolation.
- **Claude is launched via .zshrc** (not `zsh -c`) to preserve TTY for setRawMode.
- **Claude binary path** resolved dynamically via `command -v claude` + `readlink -f`. Added to both PATH in .zshenv and process-exec in sandbox profile.
- **mktemp on macOS** requires X pattern at end of template (`.sb` suffix added after mktemp call).
- **Session persistence** uses `~/.parcai/claude-home/` (global, not per-project) — completely independent from host `~/.claude`.
- **JSON parsing** in parcai is sed-based (no jq dependency). Fragile for edge cases but acceptable for user-controlled .parcai.json.
- **`file-ioctl`** required on `/dev/tty` and `/dev/ttys*` for terminal raw mode (Claude's TUI).
- **`(literal "/")`** required in sandbox profile for path resolution (zsh aborts without it).

## Known limitations and issues

See TODO.md for the prioritized list. Key issues:
- Proxy failure is silent (warns but continues with unmasked fake .env)
- Broad home read (`subpath {{HOME}}`) — some dirs not in deny list are readable
- sandbox-exec deprecated by Apple (no alternative exists)
- No PID namespace on macOS
- Proxy buffers entire response body in memory

## Building and testing

```bash
# No build step — parcai is a bash script, proxy is a Node.js script

# Run isolation tests (inside parcai sandbox)
parcai --shell
./tests/test_isolation.sh

# Run secret masking tests
parcai --secrets .env.test --shell
./tests/test_secrets.sh

# Run session persistence tests (on host)
./tests/test_session.sh ./parcai
```

## File-by-file reference

| File | Lines | What it does |
|------|-------|--------------|
| `parcai` | ~808 | Main script: config, clone, sandbox, cleanup |
| `profiles/macos.sb.tpl` | ~122 | Sandbox-exec profile template |
| `proxy/parcai-proxy` | ~562 | MITM proxy for secret masking |
| `tests/test_isolation.sh` | ~158 | Filesystem/process/network isolation tests |
| `tests/test_secrets.sh` | ~110 | Secret masking verification |
| `tests/test_session.sh` | ~119 | Claude config persistence tests |
| `SPEC.md` | ~507 | Technical specification and threat model |
| `README.md` | ~245 | User-facing documentation |
| `TODO.md` | | Prioritized backlog |
