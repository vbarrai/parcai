# Feature Comparison: hazmat vs parcai

Side-by-side comparison of [dredozubov/hazmat](https://github.com/dredozubov/hazmat) and [parcai](https://github.com/vbarrai/parcai), identifying features and techniques from hazmat that could improve parcai.

---

## Table of Contents

1. [Built-in DNS/Domain Blocklist](#1-built-in-dnsdomain-blocklist)
2. [Port Blocklist (pf Firewall)](#2-port-blocklist-pf-firewall)
3. [`explain` Command (Session Contract)](#3-explain-command-session-contract)
4. [Clipboard Support in Sandbox](#4-clipboard-support-in-sandbox)
5. [Process Execution from /tmp (Compiled Languages)](#5-process-execution-from-tmp-compiled-languages)
6. [Ancestor Metadata for git](#6-ancestor-metadata-for-git)
7. [Dynamic SBPL Profile Generation](#7-dynamic-sbpl-profile-generation)
8. [Integration Manifest System](#8-integration-manifest-system)
9. [Environment Variable Safe-list](#9-environment-variable-safe-list)
10. [Pre-session Snapshots](#10-pre-session-snapshots)
11. [Direct sandbox_init() Call](#11-direct-sandbox_init-call)
12. [Runner Pattern (verbose/dry-run)](#12-runner-pattern-verbosedry-run)
13. [Multi-agent Support](#13-multi-agent-support)
14. [Prioritization Matrix](#14-prioritization-matrix)

---

## 1. Built-in DNS/Domain Blocklist

### hazmat

hazmat blocks ~40 known exfiltration domains via `/etc/hosts` (mapped to `0.0.0.0`):

| Category | Domains |
|----------|---------|
| **Tunnels** (21) | `ngrok.io`, `ngrok.com`, `ngrok-free.app`, `tunnel.cloudflare.com`, `trycloudflare.com`, `serveo.net`, `localtunnel.me`, `localhost.run`, `localxpose.io`, `pagekite.me`, `bore.digital`, `localtonet.com`, `zrok.io`, `devtunnels.ms`, `loca.lt`, `tunnelmole.com`, `playit.gg`, `pinggy.io`, `lokal.so`, `telebit.cloud`, `loophole.cloud` |
| **Paste** (8) | `pastebin.com`, `paste.ee`, `ghostbin.com`, `hastebin.com`, `dpaste.org`, `justpaste.it`, `rentry.co`, `ix.io` |
| **File sharing** (5) | `transfer.sh`, `file.io`, `gofile.io`, `catbox.moe`, `filebin.net` |
| **Webhook capture** (5) | `webhook.site`, `requestbin.com`, `pipedream.com`, `hookbin.com`, `beeceptor.com` |
| **Supply-chain C2** (1) | `sfrclak.com` (axios compromise 2026) |

### parcai

parcai already has `--blocked-domains` and `--allowed-domains` in the MITM proxy, but no default list. Users must configure everything manually.

### How to integrate

**parcai advantage: the MITM proxy is superior to `/etc/hosts`** because it sees the full hostname in CONNECT requests, so it also blocks subdomains (`sub.ngrok.io`), which `/etc/hosts` cannot do.

- Add a default blocklist in the proxy, automatically enabled when `--secrets` is active
- Make the list configurable via `.parcai.json` (`"default_blocklist": true/false`)
- Allow extending the list via `"extra_blocked_domains": [...]`
- Store the list in a separate file (`blocklist/exfiltration.txt`) for easy updates

**Effort: low** -- the filtering mechanism already exists in the proxy, just need to add the default list.

---

## 2. Port Blocklist (pf Firewall)

### hazmat

`pf` rules scoped to the `agent` user blocking non-HTTP exfiltration protocols:

| Port(s) | Protocol | Risk |
|----------|----------|------|
| 25, 465, 587 | SMTP | Email with secrets |
| 6660-6669, 6697 | IRC | C2 channel |
| 20, 21 | FTP | File upload |
| 23 | Telnet | Unencrypted remote access |
| 445 | SMB | Network sharing |
| 3389 | RDP | Remote desktop |
| 5900, 5901 | VNC | Remote control |
| 9050, 9150 | Tor SOCKS | Anonymized traffic |
| 1080 | SOCKS | Generic proxy |
| 1194, 1723, 4500 | VPN | VPN tunnel |
| 5222, 5269 | XMPP | Messaging |
| ICMP | Ping | ICMP tunneling |

### parcai

parcai uses `(deny network*)` or `(allow network*)` in sandbox-exec -- all or nothing. When networking is enabled (default), all ports are open.

### How to integrate

Two possible approaches:

**Option A -- Via MITM proxy (recommended)**: When `--secrets` is active, all traffic flows through the proxy. The proxy can reject CONNECT requests to non-standard ports. Add a port allowlist (`80, 443, 8080, 8443`) and reject everything else.

**Option B -- Via sandbox-exec**: Replace `(allow network*)` with finer-grained rules:
```scheme
(allow network-outbound (remote tcp "*:80"))
(allow network-outbound (remote tcp "*:443"))
(allow network-outbound (remote tcp "*:8080"))
(allow network-outbound (remote tcp "*:8443"))
(allow network-outbound (local tcp "*:*"))  ;; loopback for proxy
```

Option A is simpler and already in the existing execution path. Option B works even without `--secrets`.

**Effort: low to moderate** depending on the chosen option.

---

## 3. `explain` Command (Session Contract)

### hazmat

`hazmat explain` displays a complete summary of what the session will do **before** launching:

```
hazmat: session
  Mode:                 Native containment
  Why this mode:        using native containment because no Docker requirement was detected
  Project (read-write): /Users/dr/workspace/myproject
  Integrations:         go
  Host changes:         project ACL repair, git safe.directory trust
  Auto read-only:       /Users/dr/go/pkg/mod
  Pre-session snapshot: on
  Snapshot excludes:    vendor/
  Env passthrough:      GOPROXY
  Warnings:
    - Go module cache is shared read-only...
```

Also supports `--json` for CI/automation integration.

### parcai

parcai has `--dry-run` which prints the sandbox profile and clone path, but no synthetic view of "here's what will happen". Verbose mode shows technical details, not a readable contract.

### How to integrate

Add a `parcai explain` command (or enrich `--dry-run`) that displays:

```
parcai: session contract
  Project:           myproject
  Clone:             /tmp/parcai-clone-xxx
  Network:           allowed
  Secrets masking:   active (.env, .env.local)
  Blocked domains:   40 default + 2 custom
  Read-only access:  /opt/homebrew (system)
  Read-write access: clone only
  Denied paths:      ~/.ssh, ~/.aws, ... (28 paths)
  Custom allows:     /usr/local/share/fonts
  Custom denies:     ~/other-project
  Env overrides:     NODE_ENV=test
  On exit:           ask
```

**Effort: low** -- all data is already available in global variables, just needs formatting.

---

## 4. Clipboard Support in Sandbox

### hazmat

Explicit SBPL rules for clipboard access:

```scheme
(allow mach-lookup (global-name "com.apple.pboard"))
(allow ipc-posix-shm-read-data (ipc-posix-name-regex #"^com\\.apple\\.pasteboard\\."))
(allow ipc-posix-shm-write-data (ipc-posix-name-regex #"^com\\.apple\\.pasteboard\\."))
```

### parcai

parcai allows `(allow mach-lookup)` globally (all Mach services). Clipboard works implicitly but the rule is too broad.

### How to integrate

If parcai restricts `mach-lookup` in the future (which would be a security improvement), clipboard will need explicit authorization. For now, **note as tech debt**: the global `(allow mach-lookup)` is a future hardening target.

**Effort: none now, low when mach-lookup is restricted.**

---

## 5. Process Execution from /tmp (Compiled Languages)

### hazmat

```scheme
(allow process-exec (subpath "/private/tmp"))
```

Compilers (gcc, rustc, go) write temporary binaries to `/tmp` and then execute them. Without this rule, compilation fails.

### parcai

parcai allows `file-write*` on `/tmp` but NOT `process-exec`. An agent compiling Go, Rust, or C inside the sandbox will fail to execute the resulting binary.

### How to integrate

Add to `profiles/macos.sb.tpl`:

```scheme
(allow process-exec (subpath "/private/tmp"))
```

**Effort: trivial** -- one line in the template.

**Risk**: an agent could write a malicious binary to `/tmp` and execute it. Acceptable because the sandbox restricts everything the binary can do (filesystem, network, process).

---

## 6. Ancestor Metadata for git

### hazmat

For each exposed directory (read or write), hazmat adds `file-read-metadata` rules (stat only, no content) for every ancestor directory:

```scheme
;; If the project is /Users/dr/workspace/myproject:
(allow file-read-metadata (literal "/Users"))
(allow file-read-metadata (literal "/Users/dr"))
(allow file-read-metadata (literal "/Users/dr/workspace"))
```

**Why**: `git` does path canonicalization (`realpath`) and needs `stat()` on parent directories. Without this, some git operations fail silently.

### parcai

parcai allows `(allow file-read* (subpath "{{HOME}}"))` globally, so the problem doesn't arise. But this rule is overly broad.

### How to integrate

If parcai restricts `file-read*` on `$HOME` (recommended hardening), ancestor metadata rules will be needed. Pattern:

```bash
path="$CLONE_DIR"
while [ "$path" != "/" ]; do
  path=$(dirname "$path")
  echo "(allow file-read-metadata (literal \"$path\"))"
done
```

**Effort: low** -- useful when the profile is hardened.

---

## 7. Dynamic SBPL Profile Generation

### hazmat

Instead of a static template with placeholder substitution, hazmat generates the SBPL profile **programmatically** in Go. Each session gets a unique profile computed from:
- The project directory
- Active integrations (read dirs, write dirs)
- CLI extensions (`-R`, `-W`)
- Homebrew resolution
- Credential deny rules

The code uses a "last-match-wins" pattern: it writes read rules first, then write rules (which reassert access), then credential denies last (which override everything).

### parcai

Static template (`profiles/macos.sb.tpl`) with 5 placeholders: `{{CLONE}}`, `{{HOME}}`, `{{NETWORK_POLICY}}`, `{{PROXY_LOOPBACK_RULE}}`, `{{CLAUDE_EXEC_RULE}}`. Custom rules (`--allow`, `--rw`, `--deny`) are injected by concatenation in `generate_profile()`.

### How to integrate

Two levels:

**Level 1 (pragmatic)**: Keep the template but enrich the substitution. Add placeholders for read dirs, write dirs, and auto-detected integration rules. `generate_profile()` becomes smarter without changing the architecture.

**Level 2 (overhaul)**: Switch to fully programmatic generation. Would require rewriting the profile logic in bash (doable but verbose) or migrating to a more structured language.

**Recommendation**: level 1 for now, level 2 if parcai exceeds ~100 dynamic rules.

**Effort: moderate (level 1) / high (level 2).**

---

## 8. Integration Manifest System

### hazmat

YAML manifests embedded in the binary, one per toolchain:

```yaml
# integrations/go.yaml
integration:
  name: go
  version: 1
  description: Go project defaults

detect:
  files: [go.mod]

session:
  read_dirs:
    - ~/go/pkg/mod
  env_passthrough:
    - GOPATH
    - GOPROXY

backup:
  excludes:
    - vendor/

warnings:
  - "Go module cache is shared read-only"
```

**13 built-in integrations**: go, node, rust, python-poetry, python-uv, ruby-bundler, java-gradle, java-maven, haskell-cabal, elixir-mix, opentofu-plan, terraform-plan, tla-java.

**Auto-detection**: if `go.mod` exists in the project -> go integration is automatically activated.

**Security**: each `read_dir` is validated against a credential deny path list. If a manifest tries to expose `~/.ssh`, it is rejected.

### parcai

No integration system. Users must manually configure each `--allow` for module caches, toolchains, etc.

### How to integrate

Add a detection system in `run_macos()`:

```bash
# Auto-detection
[ -f "$CWD/go.mod" ]      && auto_allow_read "$HOME/go/pkg/mod"
[ -f "$CWD/package.json" ] && auto_allow_read "$HOME/.npm/_cacache"
[ -f "$CWD/Cargo.toml" ]   && auto_allow_read "$HOME/.cargo/registry"
[ -f "$CWD/pyproject.toml" ] && auto_allow_read "$HOME/.cache/uv"
```

**Phase 1**: Inline detection in the bash script (5-10 toolchains).
**Phase 2**: External config files (`integrations/*.json`) loaded dynamically.

Auto-detection would significantly improve user experience -- no need to know which paths to allow for each language.

**Effort: low (phase 1) / moderate (phase 2).**

---

## 9. Environment Variable Safe-list

### hazmat

Explicit list of "safe" environment variables allowed for passthrough. All others are filtered:

**Allowed**: `GOPATH`, `GOROOT`, `GOPROXY`, `RUSTUP_HOME`, `CARGO_HOME`, `NVM_DIR`, `PYENV_ROOT`, `JAVA_HOME`, `GEM_HOME`, `MIX_HOME`, `HEX_HOME`, `CABAL_DIR`, `STACK_ROOT`, `NPM_CONFIG_REGISTRY`, `PIP_INDEX_URL`, etc.

**Explicitly excluded** (dangerous): `NODE_OPTIONS`, `PYTHONPATH`, `GOFLAGS`, `MAVEN_OPTS`, `CGO_CFLAGS`, `CGO_LDFLAGS`, `RUBYOPT`, `PERL5OPT`, `LD_PRELOAD`, `DYLD_*`.

**Why**: `NODE_OPTIONS=--require=/path/to/malicious.js` allows injecting code into any Node process. `LD_PRELOAD` allows intercepting any system call.

### parcai

parcai injects a controlled `PATH` in `.zshenv` and forwards `env` overrides from `.parcai.json` without filtering. Dangerous host environment variables are not sanitized.

### How to integrate

In `.zshenv` generation, add explicit `unset` for dangerous variables:

```bash
# In inject_env_into_shell_config()
for dangerous in NODE_OPTIONS PYTHONPATH LD_PRELOAD DYLD_INSERT_LIBRARIES \
                 DYLD_LIBRARY_PATH GOFLAGS MAVEN_OPTS CGO_CFLAGS CGO_LDFLAGS \
                 RUBYOPT PERL5OPT BASH_ENV ENV; do
  echo "unset $dangerous" >> "$file"
done
```

**Effort: trivial** -- a few lines in the script.

**Security impact: high** -- closes a currently open injection vector.

---

## 10. Pre-session Snapshots

### hazmat

Before each session, Kopia takes an incremental snapshot of the project. Retention policy: 20 latest, 7 daily, 4 weekly. `hazmat restore --session=N` restores N sessions back (with a pre-restore snapshot so it can be undone).

### parcai

parcai uses APFS clones (copy-on-write) -- the original is never modified during the session. Changes are explicitly applied by the user after the session. No history beyond the current session.

### How to integrate

parcai's clone architecture makes snapshots less critical (the original is protected). But history would be useful for:
- Undoing an accidental `--apply`
- Comparing project state across multiple agent sessions

**Lightweight approach (without Kopia)**:

```bash
# Before apply_changes()
snapshot_dir="$SESS_DIR/snapshots/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$snapshot_dir"
rsync -a --link-dest="$CWD" "$CWD/" "$snapshot_dir/"
```

With `--link-dest`, rsync uses hard links -- the snapshot only consumes space for modified files.

**Restore command**: `parcai restore [--session=N]`

**Effort: moderate.**

---

## 11. Direct sandbox_init() Call

### hazmat

`hazmat-launch` is a CGO binary that calls `sandbox_init()` directly instead of going through `sandbox-exec`. Benefits:
- **Correct signal forwarding**: the sandboxed process IS the target process (no wrapper)
- **Native PTY handling**: no hacks needed for interactive terminal
- **One fewer layer**: `sudo -> hazmat-launch -> target` instead of `sudo -> sandbox-exec -> target`

Security validations before the call:
- Policy file path restricted by regex
- File owner verified (must be the invoker, not root)
- File mode verified (exactly 0644)
- Content verified (must contain `(deny default)`)

### parcai

parcai uses `sandbox-exec -f profile.sb /bin/zsh -i`. TTY is handled via a hack: Claude is launched from `.zshrc` (not `zsh -c`) to preserve `setRawMode`.

### How to integrate

Two options:

**Option A -- Minimal helper binary**: A small C program (~50 lines) that:
1. Reads the policy file
2. Calls `sandbox_init(policy, 0, &err)`
3. `exec()` the target shell

```c
#include <sandbox.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    char *err = NULL;
    char *policy = read_file(argv[1]);  // policy path
    if (sandbox_init(policy, 0, &err) != 0) {
        fprintf(stderr, "sandbox_init: %s\n", err);
        return 1;
    }
    execvp(argv[2], &argv[2]);  // exec target
    return 1;
}
```

Compiled with: `cc -o parcai-sandbox main.c -Wno-deprecated-declarations`

**Option B -- Stay on sandbox-exec**: The `.zshrc` hack works. The gain may not justify adding a compiled binary to a project that is intentionally 100% scripted.

**Recommendation**: Option B for now. Option A if signal or PTY issues are reported.

**Effort: low (option A) but changes the project philosophy.**

---

## 12. Runner Pattern (verbose/dry-run)

### hazmat

All system commands go through a `Runner` abstraction that:
- Displays the command before execution in verbose mode
- Shows a human-readable **reason** for each sudo call (`"creating agent user for sandbox isolation"`)
- In dry-run mode, displays what would be done without executing
- Distinguishes between normal commands, sudo, and sudo-as-agent

### parcai

parcai has `--verbose` and `--dry-run` but the implementation is ad-hoc: scattered `if [ "$VERBOSE" = true ]` checks throughout the code.

### How to integrate

Create a wrapper function:

```bash
run() {
  local reason="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] $reason: $*"
    return 0
  fi
  [ "$VERBOSE" = true ] && info "$reason: $*"
  "$@"
}

# Usage:
run "Creating APFS clone of project" cp -c -R "$src" "$dst"
run "Generating sandbox profile" generate_profile "$clone" "$home"
```

**Effort: low** -- incremental refactoring, function by function.

---

## 13. Multi-agent Support

### hazmat

A `harness` abstraction supporting Claude, Codex, and OpenCode. Each agent has:
- Its launch command
- Its config directory
- Its bootstrap files
- Its installation logic

### parcai

parcai is hardcoded to Claude (launched via `.zshrc`, persists `~/.claude/`). `--shell` allows a generic shell but without specific support for other agents.

### How to integrate

**Phase 1**: Add `--agent codex|opencode` which modifies:
- The command launched in `.zshrc`
- The config paths that are persisted
- The allowed binary in the sandbox profile

**Phase 2**: More formal abstraction if the number of supported agents grows.

**Effort: moderate (phase 1).**

---

## 14. Prioritization Matrix

| # | Feature | Security Impact | UX Impact | Effort | Priority |
|---|---------|----------------|-----------|--------|----------|
| 9 | **Env var safe-list** | **High** | Low | Trivial | **P0** |
| 5 | **Exec from /tmp** | Low | **High** | Trivial | **P0** |
| 1 | **Default domain blocklist** | **High** | Moderate | Low | **P1** |
| 3 | **`explain` command** | Low | **High** | Low | **P1** |
| 12 | **Runner pattern** | Low | Moderate | Low | **P1** |
| 8 | **Auto-detected integrations** | Moderate | **High** | Low-Moderate | **P1** |
| 2 | **Port blocklist** | Moderate | Low | Low-Moderate | **P2** |
| 6 | **Ancestor metadata** | Low | Low | Low | **P2** |
| 7 | **Dynamic SBPL** | Moderate | Moderate | Moderate | **P2** |
| 13 | **Multi-agent** | Low | Moderate | Moderate | **P2** |
| 10 | **Pre-session snapshots** | Low | Moderate | Moderate | **P3** |
| 11 | **sandbox_init() direct** | Low | Low | Low | **P3** |
| 4 | **Clipboard (mach-lookup)** | Low | Low | None | **P3** |

### Recommended Execution Plan

**Sprint 1 (quick wins)**: P0 + top P1 items -- env safe-list, exec /tmp, domain blocklist, explain command. ~1-2 days of work.

**Sprint 2 (hardening)**: auto integrations, runner pattern, port blocklist. ~2-3 days.

**Sprint 3 (evolution)**: multi-agent, dynamic SBPL, snapshots. ~1 week.
