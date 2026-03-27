# TODO — Prioritized Backlog

## P0 — Bugs (fix before release)

### ~~Proxy failure leaves fake .env without translation~~ DONE
Originals are now backed up before masking and restored if proxy fails to start.

### ~~Broad home read — missing deny rules~~ DONE
Expanded deny list to cover: cloud providers (gcloud, gh, azure, oci, terraform), package managers (cargo, npm, bun, nvm, pyenv, gem, m2, gradle), personal folders (Pictures, Movies, Music), shell history files (.zsh_history, .bash_history, .node_repl_history, .python_history, .psql_history, etc.), git credentials, and common project directories (~/Workspace, ~/Projects, ~/repos, ~/src, ~/code, ~/dev).

### ~~SPEC.md session persistence section is outdated~~ DONE
Rewritten to document ~/.parcai/claude-home/ model.

---

## P1 — Security hardening

### ~~PARCAI_HOST_CWD leaks host path info~~ DONE
Now exposes only the basename (project name), not the full absolute path.

### ~~Domain filtering is env-var only — not enforced~~ DONE
Domain filtering is now enforced at the proxy level. `--allowed-domains` and `--blocked-domains` are passed to the proxy, which rejects HTTP 403 / CONNECT 403 for non-matching domains. Subdomain matching is supported (blocking `evil.com` also blocks `sub.evil.com`). Blocked requests are logged in the audit log with `proto: "http:blocked"` or `"https:blocked"`.

### Proxy should validate upstream TLS certificates
**File:** `proxy/parcai-proxy`
**Problem:** `rejectUnauthorized: true` is set (good), but no certificate pinning. A compromised DNS could redirect API calls to a malicious server.
**Fix:** Low priority — standard TLS validation is sufficient for the threat model.

---

## P2 — Robustness

### Proxy buffers entire response body in memory
**File:** `proxy/parcai-proxy:508-512`
**Problem:** `collectBody()` buffers the complete response. Large file downloads (e.g., `npm install` fetching tarballs) could exhaust memory.
**Fix:** Add a size limit (e.g., 50MB). For responses exceeding the limit, skip token replacement and stream directly (tokens are unlikely in binary content).

### Proxy temp file cleanup on crash
**File:** `proxy/parcai-proxy:227-275`
**Problem:** `generateLeafCert()` creates temp files (`/tmp/parcai-leaf-*.key`, etc.). Cleanup is in a `finally` block, but if Node.js crashes or is killed with SIGKILL, files remain.
**Fix:** Use `os.tmpdir()` with unique prefixes and add a startup cleanup routine.

### Session hash collision
**File:** `parcai:256-263`
**Problem:** Session dir uses first 12 chars of SHA-256 of pwd. Two different project paths with the same 12-char hash prefix would share Claude config.
**Fix:** Increase to 16 or 20 chars. Risk is extremely low with 12 chars (2^48 combinations) but trivial to fix.

### JSON config parsing fragility
**File:** `parcai:82-105`
**Problem:** sed-based JSON parsing. Doesn't handle: escaped quotes in strings, `]` inside array values, multi-line values, nested objects. `.parcai.json` is user-controlled so not a security risk, but could cause confusing errors.
**Fix:** Consider shipping a minimal JSON parser or requiring `jq` as optional dependency.

---

## P3 — Features & improvements

### Streaming support in proxy for SSE responses
**Problem:** Claude's API uses Server-Sent Events (SSE) for streaming responses. The current buffer-and-replace approach waits for the full response before sending to client, breaking streaming.
**Fix:** Implement line-by-line streaming replacement for SSE (Content-Type: text/event-stream).

### Add `--deny` flag for additional deny paths
**Problem:** Users can add `--allow` and `--rw` paths but cannot add additional deny rules from CLI.
**Fix:** Add `--deny <path>` flag that appends `(deny file-read* file-write* (subpath "..."))` to the profile.

### Run proxy tests in CI
**Problem:** `test_secrets.sh` verifies the env/files but doesn't test the actual proxy MITM flow.
**Fix:** Add integration test that starts proxy, sends request with fake token, verifies real token reaches upstream.

### Homebrew formula needs update for proxy
**File:** `SPEC.md:469-489`
**Problem:** Homebrew formula only installs the `parcai` script. Needs to also install `proxy/parcai-proxy` and ensure Node.js is available.
**Fix:** Update formula to install proxy script and add Node.js as dependency.

---

## P4 — Documentation

### Update SPEC.md session persistence section
See P0 above. The section describes the old per-session + host-copy behavior.

### Document the deny list gap (readable home dirs)
Users should know that `~/.config`, `~/Library`, etc. are readable unless explicitly denied. Add a section in SPEC.md listing what IS and ISN'T blocked.

### Add troubleshooting section to README
Common issues:
- `Abort trap: 6` → claude binary not in process-exec whitelist
- `setRawMode failed` → TTY not available (zsh -c vs zsh -i)
- `installMethod is native, but claude command not found` → claude not in PATH
- `can't set tty pgrp` → file-ioctl missing for tty devices
