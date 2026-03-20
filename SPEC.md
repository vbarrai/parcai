# parcai — Lightweight shell isolation for AI agents

## Overview

`parcai` spawns an interactive shell where the process is **confined to the current working directory**. The rest of the filesystem is invisible, secrets are unreachable, and destructive system commands fail. When the user exits, modifications are discarded (Linux) or limited to the project dir (macOS).

## Usage

```bash
cd my-project
parcai            # drops into an isolated shell
claude            # runs safely — can only touch my-project/
exit              # back to normal shell
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
| **Destroying files inside project** | `rm -rf .` | Linux: overlayfs absorbs writes, original intact. macOS: APFS clone, original intact |
| **Seeing system state** | `ps aux`, `mount`, `cat /etc/passwd` | Linux: PID namespace. macOS: sandbox denies process-info |
| **Killing other processes** | `kill -9 <pid>`, `killall` | Linux: PID namespace (only sandbox PIDs visible). macOS: sandbox denies signal to external PIDs |
| **Modifying system** | `apt remove`, `brew uninstall`, `launchctl` | No write access outside `$PWD` |
| **Network exfiltration of local files** | Read secret then `curl` it out | Files aren't accessible in the first place. Optional `--no-network` for full lockdown |
| **Spawning persistent daemons** | `nohup malicious &` | Linux: PID namespace — all children die on exit. macOS: sandbox inherited by children |
| **Escaping via environment** | `$HOME`, `$PATH` manipulation | `$HOME` set to sandbox root, `$PATH` restricted to system bins |

### Out of scope

- Kernel exploits, sandbox-exec 0days, side-channel attacks.
- A determined human attacker with knowledge of the sandbox internals.
- Network-based attacks (port scanning, etc.) — use `--no-network` if needed.

---

## Network Access

AI agents (Claude, Codex, etc.) require outbound internet access for API calls. Network must work by default in the sandbox.

### Requirements

| Requirement | Why |
|---|---|
| DNS resolution | Agents call `api.anthropic.com`, `api.openai.com`, etc. |
| TLS/SSL | All API calls use HTTPS |
| Outbound TCP | HTTP/HTTPS traffic to API servers |
| `--no-network` option | Full lockdown for offline use cases |

### macOS — Network

No special handling needed. `sandbox-exec` operates at the syscall level, not the network stack. With `(allow network*)`:
- DNS resolution works natively (`/etc/resolv.conf` is readable via system path whitelist)
- TLS works natively (system certificates in `/System/Library/` and `/Library/Keychains/` are readable)
- All outbound connections are allowed

With `--no-network`, replace `(allow network*)` with `(deny network*)`. The agent cannot make any connections, including DNS.

### Linux — Network

**Default mode (network allowed):**

Network works because we do NOT use `--net` in `unshare`, so the sandbox shares the host's network namespace. However, `pivot_root` removes the host filesystem, which means DNS and TLS config files must be explicitly preserved.

Critical files to bind-mount read-only into the new root **before** `pivot_root`:

```
/etc/resolv.conf          → DNS resolver configuration
/etc/nsswitch.conf        → Name service switch (DNS lookup order)
/etc/hosts                → Local hostname resolution
/etc/ssl/certs/           → TLS certificate bundle (Debian/Ubuntu)
/etc/pki/tls/certs/       → TLS certificate bundle (RHEL/Fedora)
/etc/ca-certificates/     → CA certificates config
/usr/share/ca-certificates/ → CA certificate files
/usr/lib/ssl/             → OpenSSL config and symlinks
```

The bind-mount order matters:
1. Bind-mount `/etc` read-only (includes resolv.conf, nsswitch.conf, hosts)
2. Bind-mount `/usr` read-only (includes ssl libs and ca-certificates)
3. These are already in the system dirs loop — no extra step needed, but verify they're present

**`--no-network` mode:**

Add `--net` flag to `unshare`. This creates a new network namespace with only a loopback interface. No outbound connections possible — DNS, TCP, everything fails.

```bash
unshare --mount --pid --net --fork --map-root-user -- /bin/sh -c '...'
```

### Network Summary

| | Default | `--no-network` |
|---|---|---|
| **macOS** | `(allow network*)` — everything works | `(deny network*)` — everything blocked |
| **Linux** | Host network namespace shared. DNS/TLS work via bind-mounted `/etc`, `/usr` | `unshare --net` — isolated namespace, loopback only |

---

## macOS Backend — `sandbox-exec` + APFS clone

### Why APFS clone?

`sandbox-exec` restricts access but the agent still writes directly to `$PWD`. If it runs `rm -rf .`, the project files are gone. APFS clones (`cp -c`) create an instant, zero-cost copy-on-write duplicate. The agent works on the clone; the original is untouched.

### Flow

```
1. CLONE=$(mktemp -d)/$(basename $PWD)
2. cp -c -r $PWD $CLONE              # APFS clone: instant, zero disk cost
3. Generate .sb profile (deny-all + whitelist CLONE only)
4. sandbox-exec -f profile.sb /bin/zsh   (CWD = CLONE)
5. On exit:
   - Ask user: "Apply changes to original? [y/N]"
   - If yes: rsync CLONE -> original
   - Cleanup CLONE and profile
```

### Sandbox Profile

```scheme
(version 1)

;; ============================================================
;; DENY EVERYTHING BY DEFAULT
;; ============================================================
(deny default)

;; ============================================================
;; PROCESS EXECUTION (restricted to system binaries only)
;; ============================================================
(allow process-exec
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/usr/sbin")
  (subpath "/sbin")
  (subpath "/opt/homebrew/bin")          ;; homebrew (Apple Silicon)
  (subpath "/usr/local/bin"))            ;; homebrew (Intel) + claude, node, etc.

(allow process-fork)
(allow signal (target self))             ;; can only signal own processes

;; ============================================================
;; FILESYSTEM — WRITE ACCESS (clone directory only)
;; ============================================================
(allow file-read* file-write* file-write-data file-write-flags
       file-write-mode file-write-owner file-write-setugid
       file-write-times file-write-unlink
  (subpath "{CLONE}"))

;; ============================================================
;; FILESYSTEM — READ-ONLY ACCESS (minimal system paths)
;; ============================================================
(allow file-read*
  ;; System libraries and binaries
  (subpath "/usr/lib")
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/usr/sbin")
  (subpath "/sbin")
  (subpath "/Library/Frameworks")
  (subpath "/System")
  (subpath "/opt/homebrew")
  (subpath "/usr/local")

  ;; System config (read-only)
  (subpath "/etc")
  (subpath "/private/etc")
  (subpath "/var/select")
  (subpath "/private/var/select")

  ;; Temp (for sandbox profile itself + tools that need tmp)
  (subpath "/private/tmp")
  (subpath "/tmp")

  ;; Device files
  (literal "/dev/null")
  (literal "/dev/zero")
  (literal "/dev/random")
  (literal "/dev/urandom")
  (literal "/dev/tty")
  (regex #"^/dev/ttys[0-9]+$")
  (literal "/dev/fd")
  (subpath "/dev/fd"))

;; Shell config (read-only, so prompt works)
(allow file-read*
  (literal "{HOME}/.zshrc")
  (literal "{HOME}/.zshenv")
  (literal "{HOME}/.zprofile")
  (literal "{HOME}/.bashrc")
  (literal "{HOME}/.bash_profile")
  (literal "{HOME}/.profile"))

;; Claude config (read-only, so claude can start)
(allow file-read*
  (subpath "{HOME}/.claude"))

;; Claude needs to write to its own state dir inside the clone
(allow file-read* file-write*
  (subpath "{CLONE}/.claude"))

;; ============================================================
;; DENY sensitive paths explicitly (belt + suspenders)
;; ============================================================
(deny file-read* file-write*
  (subpath "{HOME}/.ssh")
  (subpath "{HOME}/.aws")
  (subpath "{HOME}/.gnupg")
  (subpath "{HOME}/.config/gcloud")
  (subpath "{HOME}/.kube")
  (subpath "{HOME}/.docker")
  (subpath "{HOME}/Documents")
  (subpath "{HOME}/Desktop")
  (subpath "{HOME}/Downloads")
  (literal "{HOME}/.env")
  (literal "{HOME}/.netrc")
  (literal "{HOME}/.npmrc"))

;; ============================================================
;; PROCESS VISIBILITY — deny inspecting other processes
;; ============================================================
(deny process-info*)

;; Allow inspecting own process (needed for shell to function)
(allow process-info* (target self))
(allow process-info-pidinfo)
(allow process-info-pidfdinfo)

;; ============================================================
;; NETWORK — allowed by default (claude needs API access)
;; When --no-network: replace with (deny network*)
;; ============================================================
(allow network*)

;; ============================================================
;; IPC — minimal for shell operation
;; ============================================================
(allow ipc-posix-shm-read-data)
(allow ipc-posix-shm-write-data)
(allow mach-lookup)

;; ============================================================
;; SYSCTL — read-only system info
;; ============================================================
(allow sysctl-read)
```

### Guarantees

| Property | Guaranteed? | Mechanism |
|---|---|---|
| Cannot read files outside project | **Yes** | sandbox-exec deny default + subpath whitelist |
| Cannot write files outside project | **Yes** | sandbox-exec deny default + APFS clone |
| Cannot destroy original project | **Yes** | Agent works on APFS clone, not original |
| Cannot see other processes | **Partial** | `deny process-info*` blocks most inspection, but not perfect — macOS has no PID namespace |
| Cannot kill other processes | **Yes** | `signal (target self)` restricts signals to own process tree |
| Cannot access secrets | **Yes** | Explicit deny on ~/.ssh, ~/.aws, etc. + deny default blocks everything else |
| Children inherit sandbox | **Yes** | sandbox-exec policy is inherited by all child processes |
| Network works | **Yes** | `(allow network*)` + system paths readable for DNS/TLS |

### Limitations

- `sandbox-exec` is deprecated by Apple but still functional (macOS 15+). No CLI alternative exists.
- No PID namespace on macOS — `ps aux` is blocked by `deny process-info*` but not 100% airtight.
- APFS clone requires APFS filesystem (default since macOS 10.13, 2017).
- First-time cost: APFS clone is O(1) for disk space but O(n) for metadata of many small files.

---

## Linux Backend — namespaces + overlayfs + pivot_root

### Mechanism

Full namespace isolation: the agent process gets its own filesystem view, process tree, and optionally its own network stack. `pivot_root` replaces the root filesystem entirely (stronger than `chroot`).

### Flow

```bash
WORK=$(mktemp -d /tmp/parcai-XXXXXXXX)
mkdir -p "$WORK"/{upper,work,merged,root}
CWD=$(pwd)
DIRNAME=$(basename "$CWD")

# Determine unshare flags (add --net if --no-network)
UNSHARE_FLAGS="--mount --pid --fork --map-root-user"

# Enter new namespaces
unshare $UNSHARE_FLAGS -- /bin/sh -c '
  WORK='"$WORK"'
  CWD='"$CWD"'
  DIRNAME='"$DIRNAME"'

  # 1. Mount tmpfs for upper layer (writes go here, never touch original)
  mount -t tmpfs tmpfs "$WORK/upper"
  mkdir -p "$WORK/upper/upper" "$WORK/upper/work"

  # 2. Overlay: lowerdir=original (read-only), upperdir=tmpfs (absorbs writes)
  mount -t overlay overlay \
    -o lowerdir="$CWD",upperdir="$WORK/upper/upper",workdir="$WORK/upper/work" \
    "$WORK/merged"

  # 3. Build minimal root filesystem
  ROOT="$WORK/root"

  # Bind-mount system dirs read-only
  # IMPORTANT: /etc and /usr MUST be included for DNS/TLS to work
  #   /etc/resolv.conf    → DNS resolution
  #   /etc/nsswitch.conf  → name service switch
  #   /etc/hosts          → local hostname resolution
  #   /etc/ssl/certs/     → TLS certificates (Debian/Ubuntu)
  #   /etc/pki/tls/certs/ → TLS certificates (RHEL/Fedora)
  #   /usr/lib/ssl/       → OpenSSL config
  #   /usr/share/ca-certificates/ → CA certificate files
  for dir in usr lib lib64 bin sbin etc; do
    if [ -d "/$dir" ]; then
      mkdir -p "$ROOT/$dir"
      mount --bind "/$dir" "$ROOT/$dir"
      mount -o remount,bind,ro "$ROOT/$dir"
    fi
  done

  # Mount fresh proc/dev/tmp
  mkdir -p "$ROOT/proc" "$ROOT/dev" "$ROOT/tmp"
  mount -t proc proc "$ROOT/proc"
  mount -t tmpfs tmpfs "$ROOT/dev"
  # Create minimal device nodes
  cp -a /dev/null /dev/zero /dev/random /dev/urandom /dev/tty "$ROOT/dev/" 2>/dev/null
  mount -t tmpfs tmpfs "$ROOT/tmp"

  # Mount project overlay into the new root
  mkdir -p "$ROOT/project"
  mount --move "$WORK/merged" "$ROOT/project"

  # 4. pivot_root: swap root filesystem
  mkdir -p "$ROOT/oldroot"
  cd "$ROOT"
  pivot_root . oldroot

  # Unmount old root (now at /oldroot) — makes entire host FS invisible
  umount -l /oldroot
  rmdir /oldroot

  # 5. Launch shell
  cd /project
  export HOME=/project
  export PARCAI=1
  export PARCAI_BACKEND=unshare
  export PS1="[parcai] \w \$ "
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
  exec /bin/sh
'

# Cleanup on exit (automatic — namespace destruction unmounts everything)
rm -rf "$WORK"
```

### Guarantees

| Property | Guaranteed? | Mechanism |
|---|---|---|
| Cannot read files outside project | **Yes** | `pivot_root` + `umount -l /oldroot` — host FS physically detached |
| Cannot write files outside project | **Yes** | overlayfs: all writes go to tmpfs upper layer |
| Cannot destroy original project | **Yes** | Original is lowerdir (read-only) in overlay |
| Cannot see other processes | **Yes** | PID namespace — only sandbox processes visible |
| Cannot kill other processes | **Yes** | PID namespace — other PIDs don't exist |
| Cannot access secrets | **Yes** | Host filesystem completely unmounted |
| Children inherit isolation | **Yes** | Namespaces are inherited by all child processes |
| All changes discarded on exit | **Yes** | tmpfs overlay + namespace cleanup |
| Network works (default) | **Yes** | Host network namespace shared + `/etc`, `/usr` bind-mounted for DNS/TLS |
| Network blocked (`--no-network`) | **Yes** | `unshare --net` — isolated namespace, loopback only |

### Root vs Rootless

| Feature | With root | Rootless (`--map-root-user`) |
|---|---|---|
| Mount namespace | Yes | Yes |
| PID namespace | Yes | Yes |
| overlayfs | Yes | Kernel ≥ 5.11 |
| pivot_root | Yes | Yes |
| Network namespace | Yes | Yes (limited without slirp4netns) |

Target: rootless with `--map-root-user`. Requires `kernel.unprivileged_userns_clone=1` (default on Ubuntu, Fedora; check on Debian/RHEL).

### Fallback: Lightweight Mode (no overlayfs)

If overlayfs is unavailable:
1. `unshare --mount --pid --fork --map-root-user`
2. Remount everything as read-only EXCEPT `$CWD` and `/tmp`
3. No protection against writes to `$CWD` itself — warn the user

---

## Applying Changes (both platforms)

When the user exits the sandbox:

```
parcai: session ended.
Files modified in sandbox:
  M  src/app.ts
  A  src/new-file.ts
  D  src/old-file.ts

Apply changes to original project? [y/N]
```

- **Linux**: diff the overlay upper layer against the original, apply with rsync.
- **macOS**: diff the APFS clone against the original, apply with rsync.
- **If declined**: changes are discarded (tmpfs destroyed / clone deleted).

This ensures the original project is NEVER modified without explicit user consent.

---

## CLI Interface

```
parcai [options]

Options:
  --allow <path>     Additional path to whitelist (read-only). Repeatable.
  --rw <path>        Additional path to whitelist (read-write). Repeatable.
  --no-network       Deny all network access inside the sandbox.
  --apply            Auto-apply changes on exit (skip confirmation).
  --discard          Auto-discard changes on exit (skip confirmation).
  --dry-run          Print the sandbox config without executing.
  --verbose          Show sandbox setup details.
  --help             Show help.
  --version          Show version.
```

### Environment Inside the Sandbox

- `$PWD` points to the project directory (Linux: `/project`, macOS: clone path).
- `$PARCAI=1` — tools can detect they're sandboxed.
- `$PARCAI_BACKEND=sandbox-exec|unshare` — which backend is active.
- `$HOME` is set to the project directory (no home dir access).
- `$PATH` is restricted to system binaries only.
- Shell prompt is prefixed with `[parcai]` to indicate isolation.

---

## Verification Checklist

Before shipping, each backend must pass:

```bash
# Inside parcai shell, ALL of these must fail:
cat ~/.ssh/id_rsa           # → error / file not found
ls ~/                       # → error / only project visible
cat /etc/shadow             # → error (Linux: file not found, macOS: denied)
rm -rf /                    # → error / no effect on host
ps aux                      # → only sandbox processes (Linux) / denied (macOS)
kill -9 1                   # → error / denied
touch /tmp/escape           # → OK (tmp is isolated too)
echo "pwned" > /etc/hosts   # → error / read-only or denied
curl -s https://api.anthropic.com  # → works (unless --no-network)
python3 -c "import os; os.listdir('/Users')"  # → error / denied

# Network verification:
curl -s https://api.anthropic.com  # → must succeed (default mode)
parcai --no-network                # then: curl → must fail
```

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
  parcai              # the shell script (entry point)
  profiles/
    macos.sb.tpl      # sandbox-exec profile template
  tests/
    test_isolation.sh # verification checklist as automated tests
  README.md
  LICENSE
```
